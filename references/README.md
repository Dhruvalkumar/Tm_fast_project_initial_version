# Siemens TM FAST references

## Purpose

This guide identifies the Siemens documentation used as the reference
baseline for the TM FAST / URM14 project.

The documents explain the module interfaces, FPGA application workflow,
PLC integration and application deployment. They do not establish that
the project's implementation has passed functional or hardware testing.

Siemens documents are linked at their official source rather than
redistributed in this repository.

## 1. Equipment manual

**Title:** Technology module TM FAST (6ES7554-1AA00-0AB0)
**Baseline edition:** 04/2023
**Document identifier:** A5E52301130-AA
**Length:** 70 pages

[Official Siemens source - article 109816087](https://support.industry.siemens.com/cs/ww/en/view/109816087)

Use this reference for:

- Module capabilities, connections and electrical interfaces.
- Hardware configuration and cyclic address space.
- Module diagnostics and application management.
- TMFASTControlREC, record 100.
- TMFASTUserWriteREC, record 101.
- TMFASTUserReadREC, record 102.

Project relevance: establishes the hardware and PLC-facing interface
requirements against which the URM14 application must be checked.

## 2. Programming manual

**Title:** Creating a TM FAST application
**Baseline edition:** 05/2023
**Document identifier:** A5E52559861-AA
**Length:** 41 pages

[Official Siemens source - article 109816088](https://support.industry.siemens.com/cs/ww/en/view/109816088)

Relevant sections in this baseline edition:

- Section 3.1: generating a TM FAST application.
- Section 3.2: configuration of the system logic.
- Section 3.3: interfaces of the user application logic.
- Section 3.4: type definitions and constants.
- Chapter 4: loading an application onto the module.

Project relevance:

- Distinguishes Siemens system logic from custom VHDL user logic.
- Defines configuration parameters and user-logic interfaces.
- Describes cyclic CTRL_IF/FB_IF and acyclic WR_REC/RD_REC interfaces.
- Documents reset, CPU STOP and record-handshake behavior.
- Describes generating UPD and DB files with MFCT from the Quartus
  RBF file and the public IP configuration VHDL file.

The interface entity TFL_FAST_USER_e.vhd is defined by Siemens.
The baseline manual states that its code must not be changed.

## 3. Getting Started application example

**Title:** S7-1500 TM FAST - Getting Started
**Baseline edition:** V1.0, 09/2023
**Siemens article:** 109823442
**Length:** 27 pages

[Official Siemens example PDF](https://support.industry.siemens.com/cs/attachments/109823442/109823442_Getting_Started_TM-FAST_DOC_V1.0_en.pdf)

Use this reference to understand the complete engineering workflow:
the Siemens base project, replacement of the example architecture,
Quartus configuration, application packaging and TIA integration.

The example covers PWM, incremental counting and cam functions.
Those example functions must not be presented as implemented features
of this URM14 project without corresponding source and test evidence.

The example lists TIA Portal V17 or higher and Quartus Prime V22.1.
These are example-environment versions, not a record of the tool
versions used to build this project's individual revisions.

## 4. CPU-based application download example

**Title:** Downloading a TM FAST application from the S7 CPU
**Baseline edition:** V1.0, 10/2023
**Siemens article:** 109823442
**Length:** 21 pages

[Official Siemens CheckUserLogic example PDF](https://support.industry.siemens.com/cs/attachments/109823442/109823442_CheckUserLogic_DOC_V1.0_en.pdf)

Use this reference for:

- Checking ApplicationID and UserLogicVersion.
- Storing a generated application in a PLC data block.
- Downloading and activating the application from the S7 CPU.
- Understanding CheckUserlogicdata, LTMFAST_AppDownload and
  LTMFAST_ControlREC.

This is an application identity and deployment example.
It is not a functional testbench for the URM14 VHDL implementation.
Use of this deployment method in the project remains to be verified
against the PLC source.

## Recommended reading order

1. Equipment manual: hardware, connections and address space.
2. Programming manual: configuration and user-logic interfaces.
3. Getting Started: worked engineering and integration example.
4. CPU download example: application management where applicable.

## Edition and duplicate handling

The listed editions identify the documents reviewed for this project.
Siemens may replace downloads with newer editions at the same URL.
Check the document identifier and edition before following page or
section references.

A newer programming-manual edition, 07/2025, A5E52559861-AB, was
identified during the reference review. It is not substituted silently
for the 05/2023 baseline.

The supplied equipment-manual collection contained:

- Three byte-identical copies of A5E52301130-AA, 04/2023.
- A differently named reproduction with identical extracted text.
- An offline HTML edition with the same document identifier and edition.

These are represented by one equipment-manual entry above.

## Attribution and verification

The linked documents are Siemens publications. Their applicable
copyright notices and usage terms remain with Siemens.

Project documentation should cite the relevant document and section
when deriving configuration or interface requirements. Implementation
claims must be supported separately by source review, build reports,
simulation results or recorded hardware tests.
