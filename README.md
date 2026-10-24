# TM FAST / URM14 Project

Development repository for Dhruval's Siemens TM FAST project:
URM14 sensor communication, FPGA user logic, PLC integration,
and HMI diagnostics.

## Current repository contents

This initial snapshot contains the historical Python
sensor experiments and their existing measurement logs.

See [sensor documentation](sensor/README.md) for file purposes,
communication settings, dependencies and known limitations.

## Repository organization

Components are reviewed and documented before inclusion.
Each component includes its purpose, dependencies, configuration,
and available verification evidence.

## Review and import status

| Area | Repository status |
| --- | --- |
| Python sensor experiments | Imported with unchanged source contents and clearer filenames |
| Historical sensor logs | Imported; not sufficient to establish accuracy |
| Sensor documentation | Initial review documented; hardware details outstanding |
| Siemens manuals and configuration | Pending review and import |
| Quartus and VHDL | Pending review and import |
| UPD generation | Pending review and import |
| TIA project without HMI | Pending review and import |
| TIA project with HMI | Pending review and import |
| Hardware test procedures and results | Pending documentation |

Pending import does not mean that the corresponding project work
has not been implemented.

## Verification status

This repository is under review and is not a validated release.
Source inspection, compilation, simulation and hardware results
will be recorded separately.

Known limitations of the Python experiments are documented in
sensor/README.md. Historical logs are preserved without modification.
