# ============================================================================
# SQL Pipeline for Defender for Cloud Findings
# ============================================================================
# Architecture: Defender for Cloud → Continuous Export → Event Hub
#               → Stream Analytics → Azure SQL _Raw → MERGE procs → Typed tables
#               → Power BI
#
# Resources created:
#   1.  Resource Group
#   2.  Event Hub Namespace + 2 Event Hubs (AVM module)
#   3.  Hub-level Send auth rules (CE) + Listen auth rules (ASA)
#   4.  Consumer groups for ASA (Standard SKU only; Basic uses $Default)
#   5.  Azure SQL Server (Entra-only auth) + Findings DB + Job Metadata DB
#   6.  Firewall rule — allow Azure services
#   7.  User-Assigned Managed Identity (Elastic Job Agent)
#   8.  Elastic Job Agent + UMI assignment (via azapi)
#   9.  Stream Analytics Jobs × 2 (Assessments + SubAssessments)
#   10. Stream Analytics Inputs (Event Hub → ASA, MI auth)
#   11. Stream Analytics Outputs (ASA → SQL _Raw tables, MI auth)
#   12. RBAC: ASA → Event Hub Data Receiver, CE service principal → Event Hub Data Sender
#   13. Continuous Export automations (Assessments + SubAssessments → Event Hub, trusted service mode)
#
# What is NOT managed by Terraform (run bootstrap scripts after deployment):
#   - SQL schema (raw + typed tables, indexes) → 02-create-findings-schema.sql
#   - SQL permissions (ASA MI + Elastic Job UMI) → 03-configure-identities-and-permissions.sql
#   - Elastic Job target groups + job steps → Setup-ElasticJobScheduler.sql
#   - Stored procedures (MERGE) → usp_MergeSecurityAssessments.sql / usp_MergeSecuritySubAssessments.sql

data "azurerm_client_config" "current" {}

# ════════════════════════════════════════════════════════════════════════════════
# Locals
# ════════════════════════════════════════════════════════════════════════════════
# Event Hub Basic SKU only supports the $Default consumer group.
# Standard SKU supports up to 20 consumer groups per hub.

locals {
  asa_consumer_group = var.eventhub_sku == "Basic" ? "$Default" : "asa-consumer"
}

# ════════════════════════════════════════════════════════════════════════════════
# Resource Group
# ════════════════════════════════════════════════════════════════════════════════

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ════════════════════════════════════════════════════════════════════════════════
# Event Hub Namespace + Event Hubs (AVM Module)
# ════════════════════════════════════════════════════════════════════════════════
# Same module and pattern as the ADX pipeline (../).
# CE uses SAS-based auth (connection strings) to send events.

module "eventhub_namespace" {
  source  = "Azure/avm-res-eventhub-namespace/azurerm"
  version = "0.1.0"

  name                = var.eventhub_namespace_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku                 = var.eventhub_sku
  enable_telemetry    = false

  # SAS auth is disabled — all consumers use Managed Identity / trusted service.
  # ASA uses MI + "Azure Event Hubs Data Receiver" RBAC.
  # CE uses trusted service mode + "Azure Event Hubs Data Sender" RBAC.
  local_authentication_enabled  = false
  public_network_access_enabled = true

  event_hubs = {
    (var.eventhub_assessments_name) = {
      namespace_name      = var.eventhub_namespace_name
      resource_group_name = azurerm_resource_group.this.name
      partition_count     = var.eventhub_partition_count
      message_retention   = var.eventhub_message_retention
    }
    (var.eventhub_subassessments_name) = {
      namespace_name      = var.eventhub_namespace_name
      resource_group_name = azurerm_resource_group.this.name
      partition_count     = var.eventhub_partition_count
      message_retention   = var.eventhub_message_retention
    }
  }

  tags = var.tags
}

# ────────────────────────────────────────────────────────────────
# Hub-level Send authorization rules (for Continuous Export — SAS mode only)
# ────────────────────────────────────────────────────────────────
# REMOVED: Environment enforces disableLocalAuth on Event Hub.
# CE now uses trusted service mode (no SAS keys).
# ASA now uses Managed Identity auth (no SAS keys).
# All SAS authorization rules have been removed.

# ────────────────────────────────────────────────────────────────
# RBAC: ASA Managed Identity → Event Hub Data Receiver
# ────────────────────────────────────────────────────────────────
# Each ASA job's system-assigned MI needs "Azure Event Hubs Data Receiver"
# on its respective Event Hub to read messages.

resource "azurerm_role_assignment" "asa_assessments_eh_receiver" {
  scope                = module.eventhub_namespace.resource_eventhubs[var.eventhub_assessments_name].id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_stream_analytics_job.assessments.identity[0].principal_id
}

resource "azurerm_role_assignment" "asa_subassessments_eh_receiver" {
  scope                = module.eventhub_namespace.resource_eventhubs[var.eventhub_subassessments_name].id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_stream_analytics_job.subassessments.identity[0].principal_id
}

# ────────────────────────────────────────────────────────────────
# RBAC: CE (Windows Azure Security Resource Provider) → Event Hub Data Sender
# ────────────────────────────────────────────────────────────────
# "Windows Azure Security Resource Provider" is the first-party service principal
# used by Defender for Cloud / Continuous Export when trusted service mode is enabled.
# Object ID is well-known: look it up via data source.

data "azuread_service_principal" "defender_ce" {
  display_name = "Windows Azure Security Resource Provider"
}

resource "azurerm_role_assignment" "ce_assessments_eh_sender" {
  scope                = module.eventhub_namespace.resource_eventhubs[var.eventhub_assessments_name].id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = data.azuread_service_principal.defender_ce.object_id
}

resource "azurerm_role_assignment" "ce_subassessments_eh_sender" {
  scope                = module.eventhub_namespace.resource_eventhubs[var.eventhub_subassessments_name].id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = data.azuread_service_principal.defender_ce.object_id
}

# ────────────────────────────────────────────────────────────────
# Consumer Groups for ASA (Standard SKU only)
# ────────────────────────────────────────────────────────────────
# Basic SKU only supports $Default. If you upgrade to Standard, these
# dedicated groups avoid conflicts with other consumers.

resource "azurerm_eventhub_consumer_group" "asa_assessments" {
  count               = var.eventhub_sku == "Basic" ? 0 : 1
  name                = "asa-consumer"
  namespace_name      = module.eventhub_namespace.resource.name
  eventhub_name       = var.eventhub_assessments_name
  resource_group_name = azurerm_resource_group.this.name

  depends_on = [module.eventhub_namespace]
}

resource "azurerm_eventhub_consumer_group" "asa_subassessments" {
  count               = var.eventhub_sku == "Basic" ? 0 : 1
  name                = "asa-consumer"
  namespace_name      = module.eventhub_namespace.resource.name
  eventhub_name       = var.eventhub_subassessments_name
  resource_group_name = azurerm_resource_group.this.name

  depends_on = [module.eventhub_namespace]
}

# ════════════════════════════════════════════════════════════════════════════════
# Azure SQL Server (Entra-only authentication)
# ════════════════════════════════════════════════════════════════════════════════
# Uses Entra ID exclusively (no SQL auth passwords). The bootstrap scripts
# use sqlcmd -G (Entra auth) for all database operations.

resource "azurerm_mssql_server" "this" {
  name                = var.sql_server_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  version             = "12.0"
  minimum_tls_version = "1.2"
  express_vulnerability_assessment_enabled = true

  azuread_administrator {
    login_username              = var.sql_entra_admin_login
    object_id                   = var.sql_entra_admin_object_id != "" ? var.sql_entra_admin_object_id : data.azurerm_client_config.current.object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }

  tags = var.tags
}

# Allow Azure services (ASA managed identity, Elastic Jobs) to reach SQL
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# ────────────────────────────────────────────────────────────────
# Findings Database (raw staging + typed tables + stored procedures)
# ────────────────────────────────────────────────────────────────
# GP_S_Gen5_2 = serverless General Purpose, 2 vCores, auto-pause capable.
# Schema is created by bootstrap scripts, not Terraform.

resource "azurerm_mssql_database" "findings" {
  name                        = var.sql_findings_db_name
  server_id                   = azurerm_mssql_server.this.id
  sku_name                    = var.sql_db_sku
  min_capacity                = var.sql_min_capacity
  auto_pause_delay_in_minutes = var.sql_auto_pause_delay
  max_size_gb                 = var.sql_max_size_gb

  tags = var.tags
}

# ────────────────────────────────────────────────────────────────
# Job Metadata Database (Elastic Job Agent)
# ────────────────────────────────────────────────────────────────
# Must be at least Standard S0 — serverless is NOT supported for job metadata.

resource "azurerm_mssql_database" "job_metadata" {
  name        = var.sql_job_db_name
  server_id   = azurerm_mssql_server.this.id
  sku_name    = "S0"
  max_size_gb = 2

  tags = var.tags
}

# ════════════════════════════════════════════════════════════════════════════════
# User-Assigned Managed Identity (for Elastic Job Agent)
# ════════════════════════════════════════════════════════════════════════════════
# The Elastic Job Agent uses this UMI to authenticate to the findings database
# and execute MERGE stored procedures. The bootstrap SQL scripts create this
# identity as a contained user with EXECUTE permission on the procs.

resource "azurerm_user_assigned_identity" "elastic_job" {
  name                = var.elastic_job_umi_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location

  tags = var.tags
}

# ════════════════════════════════════════════════════════════════════════════════
# Elastic Job Agent
# ════════════════════════════════════════════════════════════════════════════════
# azurerm ~4.0 does NOT support the `identity` block on azurerm_mssql_job_agent.
# We use azapi_update_resource to PATCH the User-Assigned Managed Identity onto
# the agent after creation. This avoids any manual post-deployment steps.
#
# After deployment, run the bootstrap scripts to configure SQL permissions:
#   03-configure-identities-and-permissions.sql
#   03a-configure-elasticjob-master-user.sql

resource "azurerm_mssql_job_agent" "this" {
  name        = var.elastic_job_agent_name
  location    = var.location
  database_id = azurerm_mssql_database.job_metadata.id

  tags = var.tags

  # azapi_update_resource manages the identity block separately.
  # Prevent azurerm from trying to remove it on every apply.
  lifecycle {
    ignore_changes = [identity]
  }
}

# PATCH the UMI onto the Elastic Job Agent via azapi (ARM REST API).
# azurerm_mssql_job_agent doesn't expose identity, but the ARM API supports it.
resource "azapi_update_resource" "elastic_job_agent_identity" {
  type        = "Microsoft.Sql/servers/jobAgents@2024-05-01-preview"
  resource_id = azurerm_mssql_job_agent.this.id

  body = {
    identity = {
      type = "UserAssigned"
      userAssignedIdentities = {
        (azurerm_user_assigned_identity.elastic_job.id) = {}
      }
    }
  }
}

# ════════════════════════════════════════════════════════════════════════════════
# Stream Analytics Jobs (2 — one per event type)
# ════════════════════════════════════════════════════════════════════════════════
# Each job reads from its Event Hub and writes to the corresponding SQL _Raw
# staging table. The transformation is a simple passthrough — CE ARM JSON fields
# map directly to _Raw table columns. Nested objects (properties, tags,
# enrichment data) auto-serialize to NVARCHAR(MAX) at compatibility level 1.2.
#
# The heavy lifting (OPENJSON parsing, dedup, MERGE) is done by the SQL stored
# procedures, scheduled via Elastic Job Agent.

resource "azurerm_stream_analytics_job" "assessments" {
  name                                     = var.asa_assessments_job_name
  resource_group_name                      = azurerm_resource_group.this.name
  location                                 = var.location
  compatibility_level                      = "1.2"
  streaming_units                          = var.asa_streaming_units
  events_late_arrival_max_delay_in_seconds = 60
  events_out_of_order_max_delay_in_seconds = 30
  events_out_of_order_policy               = "Adjust"
  output_error_policy                      = "Stop"

  identity {
    type = "SystemAssigned"
  }

  # CE ARM JSON → SecurityAssessments_Raw
  # Columns: tenantId, type, id, name, location, kind, tags, properties,
  #          assessmentEventDataEnrichment, securityEventDataEnrichment,
  #          EventProcessedUtcTime, EventEnqueuedUtcTime, PartitionId
  # (InsertedAtUtc defaults to SYSUTCDATETIME() in SQL)
  transformation_query = <<-QUERY
    SELECT
        tenantId,
        [type],
        id,
        name,
        location,
        kind,
        tags,
        properties,
        assessmentEventDataEnrichment,
        securityEventDataEnrichment,
        System.Timestamp()     AS EventProcessedUtcTime,
        EventEnqueuedUtcTime,
        PartitionId
    INTO [sqloutput]
    FROM [ehinput]
  QUERY

  tags = var.tags
}

resource "azurerm_stream_analytics_job" "subassessments" {
  name                                     = var.asa_subassessments_job_name
  resource_group_name                      = azurerm_resource_group.this.name
  location                                 = var.location
  compatibility_level                      = "1.2"
  streaming_units                          = var.asa_streaming_units
  events_late_arrival_max_delay_in_seconds = 60
  events_out_of_order_max_delay_in_seconds = 30
  events_out_of_order_policy               = "Adjust"
  output_error_policy                      = "Stop"

  identity {
    type = "SystemAssigned"
  }

  # CE ARM JSON → SecuritySubAssessments_Raw
  # Note: uses subAssessmentEventDataEnrichment (not assessmentEventDataEnrichment)
  transformation_query = <<-QUERY
    SELECT
        tenantId,
        [type],
        id,
        name,
        location,
        kind,
        tags,
        properties,
        subAssessmentEventDataEnrichment,
        securityEventDataEnrichment,
        System.Timestamp()     AS EventProcessedUtcTime,
        EventEnqueuedUtcTime,
        PartitionId
    INTO [sqloutput]
    FROM [ehinput]
  QUERY

  tags = var.tags
}

# ════════════════════════════════════════════════════════════════════════════════
# Stream Analytics Inputs (Event Hub → ASA)
# ════════════════════════════════════════════════════════════════════════════════
# Uses Managed Identity auth (no SAS keys). Each ASA job's system-assigned MI
# is granted "Azure Event Hubs Data Receiver" on its respective Event Hub.
# Consumer group: $Default for Basic SKU, dedicated "asa-consumer" for Standard.

resource "azurerm_stream_analytics_stream_input_eventhub" "assessments" {
  name                         = "ehinput"
  stream_analytics_job_name    = azurerm_stream_analytics_job.assessments.name
  resource_group_name          = azurerm_resource_group.this.name
  eventhub_consumer_group_name = local.asa_consumer_group
  eventhub_name                = var.eventhub_assessments_name
  servicebus_namespace         = module.eventhub_namespace.resource.name
  authentication_mode          = "Msi"

  serialization {
    type     = "Json"
    encoding = "UTF8"
  }
}

resource "azurerm_stream_analytics_stream_input_eventhub" "subassessments" {
  name                         = "ehinput"
  stream_analytics_job_name    = azurerm_stream_analytics_job.subassessments.name
  resource_group_name          = azurerm_resource_group.this.name
  eventhub_consumer_group_name = local.asa_consumer_group
  eventhub_name                = var.eventhub_subassessments_name
  servicebus_namespace         = module.eventhub_namespace.resource.name
  authentication_mode          = "Msi"

  serialization {
    type     = "Json"
    encoding = "UTF8"
  }
}

# ════════════════════════════════════════════════════════════════════════════════
# Stream Analytics Outputs (ASA → SQL _Raw Tables)
# ════════════════════════════════════════════════════════════════════════════════
# Uses Managed Identity authentication (no passwords stored in Terraform state).
# The ASA system-assigned MI must be granted SELECT + INSERT on the _Raw tables.
# This is handled by the bootstrap scripts:
#   customer/bootstrap/sql/03-configure-identities-and-permissions.sql
# Pass the ASA job name(s) as the AsaJobPrincipalName parameter.

resource "azurerm_stream_analytics_output_mssql" "assessments" {
  name                      = "sqloutput"
  stream_analytics_job_name = azurerm_stream_analytics_job.assessments.name
  resource_group_name       = azurerm_resource_group.this.name
  server                    = azurerm_mssql_server.this.fully_qualified_domain_name
  database                  = azurerm_mssql_database.findings.name
  table                     = "SecurityAssessments_Raw"
  authentication_mode       = "Msi"

  depends_on = [azurerm_mssql_database.findings]
}

resource "azurerm_stream_analytics_output_mssql" "subassessments" {
  name                      = "sqloutput"
  stream_analytics_job_name = azurerm_stream_analytics_job.subassessments.name
  resource_group_name       = azurerm_resource_group.this.name
  server                    = azurerm_mssql_server.this.fully_qualified_domain_name
  database                  = azurerm_mssql_database.findings.name
  table                     = "SecuritySubAssessments_Raw"
  authentication_mode       = "Msi"

  depends_on = [azurerm_mssql_database.findings]
}

# ════════════════════════════════════════════════════════════════════════════════
# Continuous Export Automations (Defender for Cloud → Event Hub)
# ════════════════════════════════════════════════════════════════════════════════
# Uses TRUSTED SERVICE MODE — no SAS keys required.
# The "Windows Azure Security Resource Provider" service principal is granted
# "Azure Event Hubs Data Sender" RBAC on each Event Hub (see role assignments above).
# isTrustedServiceEnabled = true is set via azapi since azurerm doesn't support it.
#
# Exports both streaming events (on state change) and weekly snapshots.
# First data may take 4–24 hours to appear after creation.

resource "azapi_resource" "ce_assessments" {
  type      = "Microsoft.Security/automations@2023-12-01-preview"
  name      = "ExportToEventHub-Assessments-SQL"
  location  = var.location
  parent_id = azurerm_resource_group.this.id

  tags = var.tags

  body = {
    properties = {
      isEnabled = true
      description = "CE: Assessments → Event Hub → ASA → Azure SQL (trusted service mode)"
      scopes = [
        {
          description = "Subscription scope"
          scopePath   = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
        }
      ]
      sources = [
        {
          eventSource = "Assessments"
          ruleSets    = []
        },
        {
          eventSource = "AssessmentsSnapshot"
          ruleSets    = []
        }
      ]
      actions = [
        {
          actionType                = "EventHub"
          eventHubResourceId        = module.eventhub_namespace.resource_eventhubs[var.eventhub_assessments_name].id
          isTrustedServiceEnabled   = true
        }
      ]
    }
  }

  depends_on = [
    azurerm_role_assignment.ce_assessments_eh_sender
  ]
}

resource "azapi_resource" "ce_subassessments" {
  type      = "Microsoft.Security/automations@2023-12-01-preview"
  name      = "ExportToEventHub-SubAssessments-SQL"
  location  = var.location
  parent_id = azurerm_resource_group.this.id

  tags = var.tags

  body = {
    properties = {
      isEnabled = true
      description = "CE: SubAssessments → Event Hub → ASA → Azure SQL (trusted service mode)"
      scopes = [
        {
          description = "Subscription scope"
          scopePath   = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
        }
      ]
      sources = [
        {
          eventSource = "SubAssessments"
          ruleSets    = []
        },
        {
          eventSource = "SubAssessmentsSnapshot"
          ruleSets    = []
        }
      ]
      actions = [
        {
          actionType                = "EventHub"
          eventHubResourceId        = module.eventhub_namespace.resource_eventhubs[var.eventhub_subassessments_name].id
          isTrustedServiceEnabled   = true
        }
      ]
    }
  }

  depends_on = [
    azurerm_role_assignment.ce_subassessments_eh_sender
  ]
}
