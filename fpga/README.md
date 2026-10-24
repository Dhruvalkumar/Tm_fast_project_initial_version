# TM FAST FPGA application

## Purpose

The custom VHDL user logic implements URM14 sensor communication,
measurement processing, diagnostics and digital-output decisions
inside the Siemens TM FAST FPGA.

The S7-1500 PLC supplies operating commands and parameters.
Siemens system logic provides the interface between the PLC,
the custom user logic and the module hardware.

## Source and status

[Open the V07 user logic](v07/TM_FAST_V07_URM14_Diagnostics.vhd)

This file is an unchanged V07 baseline preserved for review.
Known functional defects are documented below.
It must not be treated as a validated release.

This initial source import is not a standalone buildable Quartus
project. The project configuration and required Siemens framework
dependencies are not yet included in this directory.

## Intended data flow

1. Receive cyclic PLC commands through CTRL_IF.
2. Optionally commit parameters received through WR_REC.
3. Schedule a sensor transaction.
4. Optionally trigger a measurement using Modbus function 06.
5. Read distance and temperature using Modbus function 03.
6. Check the response and CRC.
7. Process the measurement and update diagnostic conditions.
8. Generate output commands and publish PLC feedback.

The UART, CRC, timing and processing functions are implemented
as concurrent hardware processes and state machines.

## Interfaces used

| Interface | Role |
| --- | --- |
| CLK | User-logic clock |
| RST | Reset application state |
| CPU_STOP | Handle PLC STOP state |
| CTRL_IF | Cyclic PLC commands and parameters |
| FB_IF | Cyclic measurement and status feedback |
| WR_REC / WR_REC_NEW | Acyclic parameter data and arrival indication |
| RD_REC / RD_REC_BUSY | Acyclic diagnostic data and update coordination |
| RS485_TX(0) | Sensor transmit data |
| RS485_RX(0) | Sensor receive data |
| RS485_OE(0) | RS-485 transmit-direction control |
| DQ | Application output commands |

## Sensor communication implemented in the source

- Default sensor address: 12 (0x0C).
- UART timing assumes a 50 MHz user clock.
- BIT_TICKS = 2604, corresponding to approximately 19200 baud.
- Optional trigger: write 0x000C to register 0x0008.
- Measurement read: two registers starting at 0x0005.
- CRC16 generation and checking are implemented in VHDL.
- Default polling interval: 1500 ms.
- Default measurement wait: 300 ms.
- Default receive timeout: 50 ms.

These are implementation settings, not measured performance results.

## Processing and outputs

The source contains optional distance filtering, jump detection,
measurement-age monitoring, invalid-value handling, consecutive
failure tracking and an attempted stuck-value detector.

Threshold comparison uses hysteresis. Output commands depend on
the selected mode, operating enables and measurement-health gates:

- DQ0: forward command.
- DQ1: reverse command.
- DQ3: enable command.

These labels describe intended logical roles.
The connected equipment and physical wiring require separate
documentation and verification.

Synthetic measurement and fault-injection modes are also present.
They do not validate the physical sensor communication path.

## Known issues from static review

| Issue | Consequence |
| --- | --- |
| RX_START samples the start-bit midpoint into data bit 0 | Received data bits are misaligned |
| RX_IDLE resets frame length between received bytes | Multi-byte responses cannot accumulate correctly |
| Stuck counter advances per accepted sample but its threshold uses clock ticks | Configured stuck duration does not represent elapsed time correctly |
| Filter-shift and quality-window parameters are decoded but unused | These settings do not change processing |
| Rejected jumps do not update the accepted-distance reference | A persistent legitimate distance step can remain rejected |
| U32_MAX declaration produces a saved Quartus overflow warning | Constant representation requires correction and verification |

This list is not an exhaustive functional review.
Fixes and their verification should be recorded separately from
the unchanged baseline.

## Quartus project identification

The inspected project selects:

- Revision: TFL_MP_FAST_1.
- Top-level entity: TFL_MP_FAST_1_TOP.
- Device: 10CL025YU256A7G.
- Last recorded Quartus version: 23.1std.1 Lite Edition.
- User architecture: TM_FAST_V07_URM14_Diagnostics.

The original QSF references the application source as:
../../TM_FAST_V07_URM14_Diagnostics.vhd

Project-relative paths and framework dependencies must be preserved
or explicitly updated when preparing the reproducible build.

## Verification evidence

The supplied archive contains successful synthesis and fitter reports.
These are historical build results, not new builds performed during
this repository import.

Compilation does not establish correct UART behavior, sensor
measurements, diagnostics or output behavior. Hardware validation
of this exact baseline remains unestablished in the reviewed evidence.

## Reading order

1. Read this overview and the known issues.
2. Review the public IP configuration package when imported.
3. Read parameter selection and record handling in the user logic.
4. Follow the polling, Modbus, UART and CRC state machines.
5. Review measurement processing, output gates and feedback packing.

See the [Siemens reference guide](../references/README.md) for the
equipment manual, programming manual and integration examples.
