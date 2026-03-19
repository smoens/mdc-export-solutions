---
description: "Use when creating or editing SVG diagrams, architecture diagrams, flow diagrams, or any visual that includes Azure service icons. Covers icon sourcing, embedding rules, and the local icon library."
applyTo: "docs/assets/**/*.svg"
---

# Azure Architecture Icons

## Source

All Azure service icons in this repository come from the **official Microsoft Azure Architecture Icons** set.

- Download page: https://learn.microsoft.com/en-us/azure/architecture/icons/
- License: Microsoft permits use in architecture diagrams, training materials, and documentation.
- Version used: **Azure Public Service Icons V23** (November 2025 update).

## Local icon library

Official icon SVGs are stored locally in `docs/assets/icons/`. Always use these as the source of truth.

| File | Azure service |
|------|---------------|
| `continuous-export.svg` | Microsoft Defender for Cloud (Continuous Export context) |
| `defender-for-cloud.svg` | Microsoft Defender for Cloud |
| `event-hub.svg` | Azure Event Hubs |
| `stream-analytics.svg` | Azure Stream Analytics |
| `sql-database.svg` | Azure SQL Database |
| `resource-graph.svg` | Azure Resource Graph Explorer |
| `powershell.svg` | PowerShell |
| `power-bi.svg` | Power BI Embedded |

## Rules for using icons in SVG diagrams

1. **Always use official icons.** Never hand-draw or approximate Azure service icons. Embed the `<path>` data from `docs/assets/icons/*.svg` directly.

2. **Embed as nested `<svg>` elements.** Place each icon inside its own `<svg>` with a `viewBox="0 0 18 18"` (the native viewBox of the official icons). Scale via `width` and `height` attributes on the nested `<svg>`.

   ```xml
   <svg x="60" y="47" width="90" height="90" viewBox="0 0 18 18">
     <!-- paste official icon paths here -->
   </svg>
   ```

3. **Place icons on white cards.** Wrap each icon position with a rounded white rectangle for contrast against the diagram background:

   ```xml
   <rect x="55" y="42" width="100" height="100" rx="14" fill="#fff" filter="url(#shadow)" opacity="0.85"/>
   ```

4. **Namespace gradient IDs.** The official icons use random UUIDs as gradient/clipPath IDs. When embedding multiple icons in one SVG, rename them to avoid collisions (e.g., `dfc-grad`, `sql-grad`, `sa-grad`).

5. **Do not crop, flip, rotate, or distort** the icon shapes. This is a Microsoft licensing requirement.

6. **Add labels below icons.** Use Segoe UI, 12px, `font-weight="600"` for the service name and 11px normal weight for the subtitle.

## Adding a new icon

1. Download the latest icon pack from https://learn.microsoft.com/en-us/azure/architecture/icons/
2. Find the relevant SVG in the extracted `Azure_Public_Service_Icons/Icons/` folder.
3. Copy it to `docs/assets/icons/` with a kebab-case filename matching the service name.
4. Update `docs/assets/icons/README.md` with the new entry.

## Diagram style conventions

- Background: `#f9fafb` with `rx="12"`
- Connectors: dashed lines (`stroke-dasharray="6 4"`) in `#0078D4` at `opacity="0.4"`
- Arrowheads: solid triangles in `#0078D4` at `opacity="0.5"`
- Animated data dots: `#0078D4` primary, `#50a0e6` secondary, using `<animateMotion>` with glow filter
- Font: Segoe UI, sans-serif
- Title: 11px italic `#999` top-right corner
