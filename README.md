# mdc-export-solutions

Export and analyze **Microsoft Defender for Cloud** findings using multiple pipeline options.

## Repository Structure

```
├── automation/                     # Standalone analysis & export scripts
│   ├── Setup-ContinuousExport.ps1 # Configure Continuous Export on subscriptions
│   └── output/                    # Generated reports and Power BI setup scripts
│
├── option_d-CE-EH-ASA-SQL/        # Option D: CE → Event Hub → Stream Analytics → SQL
│   ├── README.md                  # Deployment guide, schema reference, troubleshooting
│   ├── Setup-Guide-Manual.md      # Manual deployment walkthrough (Portal + SQL)
│   ├── Stream-Analytics-SQL-Pipeline.md  # Deep-dive: CE format, ASA queries, MERGE internals
│   ├── sql/                       # SQL scripts (DDL, stored procs, Elastic Jobs)
│   └── bootstrap/                 # Automated SQL bootstrapping (PowerShell + SQL)
│
├── option_e-ARG/                   # Option E: Azure Resource Graph queries
│   ├── Export-ArgFindings.ps1      # ARG-based findings export
│   ├── Export-ForPowerBI.ps1       # Power BI export (CSV & Log Analytics modes)
│   └── resourcegraph.kql          # KQL queries for ARG
│
└── .infra/
    └── sql/                        # Terraform for Option D infrastructure
        ├── main.tf                 # All resources (~15 resource types)
        ├── variables.tf            # Input variables with defaults
        ├── outputs.tf              # Resource IDs, FQDNs, pipeline summary
        ├── providers.tf            # azurerm ~4.0 + azapi providers
        └── terraform.tfvars.example # Example variable values
```

## Pipeline Options

| Option | Path | Description |
|--------|------|-------------|
| **D** | `option_d-CE-EH-ASA-SQL/` | Continuous Export → Event Hub → Stream Analytics → Azure SQL. Full pipeline with staging tables, MERGE stored procs, and Elastic Job scheduling. Deployed via Terraform + bootstrap scripts. |
| **E** | `option_e-ARG/` | Azure Resource Graph queries. Lightweight, no infrastructure needed. Point-in-time exports only (no streaming). |

## Quick Start — Option D (SQL Pipeline)

```bash
# 1. Deploy infrastructure
cd .infra/sql/
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform init && terraform apply

# 2. Run bootstrap (schema + permissions + Elastic Job schedule)
cd ../../option_d-CE-EH-ASA-SQL/bootstrap/scripts/
./Initialize-Bootstrap.ps1 \
    -SqlServerFqdn "$(terraform -chdir=../../../.infra/sql output -raw sql_server_fqdn)" \
    -ElasticJobUmiName "$(terraform -chdir=../../../.infra/sql output -raw elastic_job_umi_name)" \
    -ElasticJobUmiClientId "$(terraform -chdir=../../../.infra/sql output -raw elastic_job_umi_client_id)" \
    -AsaAssessmentsPrincipalName "asa-defender-assessments" \
    -AsaSubAssessmentsPrincipalName "asa-defender-subassessments" \
    -SkipDatabaseCreation -SkipMasterUser

# 3. Done — bootstrap starts ASA jobs automatically
```

See [option_d-CE-EH-ASA-SQL/README.md](option_d-CE-EH-ASA-SQL/README.md) for the full walkthrough.