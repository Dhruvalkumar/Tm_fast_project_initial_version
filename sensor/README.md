# URM14 sensor communication experiments

## Purpose and status

Historical Python experiments for URM14 communication,
measurement processing, visualization and logging before
integration with Siemens TM FAST.

The source files were copied without content changes.
Only their filenames were changed for clarity.

These scripts are preserved experiments, not a validated final release.
Hardware testing has not been repeated during this repository review.

## Files and original names

| Repository file | Original filename | Purpose |
| --- | --- | --- |
| python/urm14_dashboard.py | urm.py | GUI, plotting, filtering, state labels and CSV logging |
| python/urm14_console_spike_recovery.py | urm_second.py | Console acquisition with spike rejection and recovery |
| python/urm14_console_spike_recovery_interrupt.py | urm_testing.py | Console variant with explicit keyboard-interrupt handling |
| evidence/sensor_data.csv | sensor_data.csv | One historical dashboard record |
| evidence/sensor_accuracy_log.csv | sensor_accuracy_log.csv | 33 historical measurement records; generating script not identified |

The displayed FWD, NEU and REV states are software classifications.
These Python scripts do not drive physical motor outputs.

## Communication settings in the code

- Serial port: COM5
- Modbus slave address: 12 (0x0C)
- Baud rate: 19200
- Serial format: 8 data bits, no parity, 1 stop bit
- Client timeout: 1 second
- Measurement trigger: write 0x000C to register 0x08
- Distance: read register 0x05 and divide by 10 for millimetres
- Temperature: read register 0x06 and divide by 10 for degrees Celsius

The scripts assume matching sensor communication settings.
They do not change the stored sensor address or baud rate.

## Recorded environment

The uploaded environment records Python 3.13.2 and:
- pymodbus 3.9.2
- pyserial 3.5
- matplotlib 3.10.3

requirements.txt records these direct third-party dependencies.
It is not a complete environment lock.
The original virtual environment and PyCharm settings are excluded.

## Known limitations

- Internal sensor compensation is enabled by the control value,
  while the scripts also apply a host-side temperature correction.
  This additional correction requires review.
- The dashboard overwrites sensor_data.csv in its working directory
  at startup. Preserve historical evidence before running it.
- Opening the serial port does not establish successful sensor replies.
- Measurement-trigger write responses are not checked.
- Failed temperature reads can be replaced silently with 25 C.
- Console variants also treat a zero temperature value as invalid.
- Spike rejection and recovery need review, including median history.
- The logs contain no reference-distance measurements and therefore
  do not establish measurement accuracy.
- Eight records in sensor_accuracy_log.csv are below the configured
  100 mm lower measurement limit.

## Evidence still required

- Identify the script used for the successful sensor test.
- Identify the adapter, power supply and actual wiring.
- Identify the script that generated sensor_accuracy_log.csv.
- Record repeatable hardware tests with reference measurements.

