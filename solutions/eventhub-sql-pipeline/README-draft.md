# Event Hub SQL Pipeline

Real-time ingestion of **Microsoft Defender for Cloud** findings into Azure SQL Database using a staging-then-merge pattern.

## How it works

Continuous Export streams security assessments and sub-assessments to Event Hub. Stream Analytics writes events as-is into raw staging tables. An Elastic Job runs a MERGE stored procedure every 10 minutes to deduplicate, parse the ARM JSON, and upsert into typed tables.

```
Defender for Cloud
    │  Continuous Export
    ▼
Event Hub (2 hubs)
    │  Stream Analytics (passthrough)
    ▼
SQL _Raw staging tables
    │  MERGE (Elastic Job, every 10 min)
    ▼
SQL typed tables
```

## Key concepts

| Concept | Role in this pipeline |
|---------|----------------------|
| [Continuous Export](../../docs/concepts/Continuous-Export.md) | Entry point - streams findings to Event Hub |
| [Event Hub](../../docs/concepts/Event-Hub.md) | Buffers events with partitioning |
| [Stream Analytics](../../docs/concepts/Stream-Analytics.md) | Passthrough writer from Event Hub to SQL |
| [Azure SQL Database](../../docs/concepts/Azure-SQL-Database.md) | Stores deduplicated findings in typed tables |

## Documentation

| Document | Description |
|----------|-------------|
| [README.md](README.md) | Full deployment guide, schema reference, troubleshooting |
| [Setup-Guide-Manual.md](Setup-Guide-Manual.md) | Step-by-step manual deployment via Azure Portal |
| [Stream-Analytics-SQL-Pipeline.md](Stream-Analytics-SQL-Pipeline.md) | Deep-dive into CE format, ASA queries, and MERGE internals |
| [bootstrap/](bootstrap/) | Automated SQL bootstrapping scripts |

## Infrastructure

All Azure resources are defined in [.infra/sql/](../../.infra/sql/) (Terraform). The bootstrap scripts in [bootstrap/scripts/](bootstrap/scripts/) create the SQL schema, permissions, and Elastic Job schedule.
