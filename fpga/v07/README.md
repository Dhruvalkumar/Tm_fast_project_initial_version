# V07 configuration and deployment

## Status

This directory preserves the V07 application source, public IP
configuration and historical deployment files.

The complete Quartus project and Siemens framework dependencies
are not yet included. This directory is not independently buildable.

Known functional issues are documented in the [FPGA overview](../README.md).
Deployment files are not evidence that those issues have been resolved.

## Public IP configuration

[Open the configuration source](MP_FAST_1_restored/SRC/User/TFL_FAST_USER_IP_CONF_PUBLIC_MP_FAST_1_p.vhd)

| Setting | Configured value | Purpose |
| --- | --- | --- |
| APPLICATION_ID | URM14_07 | Application identifier |
| USER_LOGIC_VERSION | V01.00.00 | Application version |
| FUNCTION_ID | 0x00000000 | Reserved identifier |
| F_CLK_USER | 50000000 Hz | User-logic clock |
| PHASE_QUANTITY | 0 | No additional user clock phases requested |
| WR_REC_DWORD_SIZE | 8 DWORDs / 32 bytes | User write-record length |
| RD_REC_DWORD_SIZE | 8 DWORDs / 32 bytes | User read-record length |
| Channel 0 direction | RS485_bidir | Bidirectional sensor communication |
| Channels 1-7 | unused | Not allocated to this application |
| Channel 0 termination | enabled | Configures channel termination |
| DI filter values | 0.5 ms | Configured digital-input filtering |
| RS485/TTL filter values | 0 ms | No configured input-filter delay |

The UART implementation assumes the configured 50 MHz clock.
Changing the clock requires reviewing UART timing and application timers.

Termination must be checked against the actual bus wiring.
The configuration file still contains older V00 comments; the table
above describes the configured values, not those historical comments.

The application name URM14_07 and version V01.00.00 are separate
identifiers. V07 does not mean that USER_LOGIC_VERSION is V07.00.00.

## Deployment files

| File | Role |
| --- | --- |
| 6ES7 554-1AA00-0AB0 URM14_07_UserLogic_V01.00.00.UPD | Generated application update package |
| URM14_07.db | Generated TIA data-block source containing application-download data |

These files are in the deployment directory.

The DB declares URM14_07 as an array of LTMFAST_typeAppDownloadData.
The corresponding Siemens library type is required when integrating
the generated source into a TIA project.

The UPD and DB represent deployment workflows described in the
[Siemens references](../../references/README.md).
Their presence does not establish which workflow the PLC project uses.

## Provenance and modifications

- User logic: copied without content changes.
- Public IP configuration: copied without content changes.
- UPD: copied byte-for-byte from the supplied V07 archive.
- DB: only the absolute path in its generated source comment was
  replaced with TFL_MP_FAST_1.rbf.
- All other DB bytes were compared against the original and matched.

The DB comment identifies TFL_MP_FAST_1.rbf and V01.00.00.
A reproducible source-to-package build has not yet been established.
Do not assume that matching filenames alone prove this relationship.

## SHA-256 checksums

User logic:
B423C6EE25AA563B00F78C2B03AE400CD69FDE4F038F6C25C08BF59AA1185588

Public IP configuration:
EE0DC06D6D87DC7D8E9E1AD566AD4151624A45429A1D0C57C09E9AF2424052B8

UPD:
6B4105708112FDF897DC4EB19BED1D4D3895A2B1336DCE0B040C45232C458A80

Original DB:
8E17E165055E30BF7AF36B97F839B00EF717ED40C3AD5DB81524A044F0923864

Repository DB after comment cleanup:
8714E2EF70E680EC5964B3C158BD42A8D5EA369503F4D8580CF6FB10A1830BF8

These checksums describe file bytes before any Git line-ending
conversion. Verify exported files before relying on byte identity.

## Remaining verification

- Restore and document the complete Quartus dependency structure.
- Confirm build tool and MFCT versions.
- Establish the relationship between source, RBF and deployment files.
- Verify the TIA integration and application identity checks.
- Record hardware behavior against a specific source revision.
