library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.TFL_FAST_USER_PUBLIC1_p.all;
use work.TFL_FAST_USER_PUBLIC2_p.all;
use work.TFL_FAST_USER_IP_CONF_p.all;

package TFL_FAST_USER_IP_CONF_PUBLIC_p is

  --------------------------------------------------------------------------
  -- V00: Mapping + handshake sanity only (no UART/Modbus yet)
  --------------------------------------------------------------------------

  -- User logic version format: <LETTER><XX>.<YY>.<ZZ>
  constant USER_LOGIC_VERSION : LOGIC_VERSION_TYPE := ( LETTER => 'V', XX => 1, YY => 0, ZZ => 0 );

  -- User application ID (8 characters)
  constant APPLICATION_ID     : APPLICATION_ID_TYPE := ( 'U', 'R', 'M', '1', '4', '_', '0', '7' );

  -- Function ID (reserved)
  constant FUNCTION_ID        : FUNCTION_ID_TYPE := x"00000000";

  -- Write/Read record sizes (DWORDs)
  constant WR_REC_DWORD_SIZE  : integer range 1 to WR_REC_DWORD_MAX_SIZE := 8;
  constant RD_REC_DWORD_SIZE  : integer range 1 to RD_REC_DWORD_MAX_SIZE := 8;

  -- user clock frequency
  constant F_CLK_USER         : integer := 50_000_000;

  -- quantity of user clock phases
  constant PHASE_QUANTITY     : integer range 0 to PHASE_MAX_QUANTITY := 0;

  --------------------------------------------------------------------------
  -- RS485 config:
  -- V00 does not use RS485 yet, but we keep CH0 reserved for later stages.
  --------------------------------------------------------------------------
  constant RS485_OR_TTL_DIRECTION : RS485_OR_TTL_DIRECTION_TYPE :=
    ( 0 => RS485_bidir,  -- CH0 reserved for URM14 later
      1 => unused,
      2 => unused,
      3 => unused,
      4 => unused,
      5 => unused,
      6 => unused,
      7 => unused );

  constant RS485_TERMINATION : RS485_TERMINATION_TYPE :=
    ( 0 => enabled,      -- keep as you had; you can disable later if needed
      others => unused );

  --------------------------------------------------------------------------
  -- DI filter times (ms)
  --------------------------------------------------------------------------
  constant DI_FILTER_USER_VAL_MS : DI_FILT_TYPE_REAL :=
    ( 0  => 0.500000,
      1  => 0.500000,
      2  => 0.500000,
      3  => 0.500000,
      4  => 0.500000,
      5  => 0.500000,
      6  => 0.500000,
      7  => 0.500000,
      8  => 0.500000,
      9  => 0.500000,
      10 => 0.500000,
      11 => 0.500000 );

  --------------------------------------------------------------------------
  -- RS485/TTL input filter (ms)
  -- For UART later: keep ~0 to preserve edges.
  --------------------------------------------------------------------------
  constant RS485_TTL_FILTER_USER_VAL_MS : RS485_TTL_FILT_TYPE_REAL :=
    ( 0 => 0.000000,  -- CH0
      1 => 0.000000,
      2 => 0.000000,
      3 => 0.000000,
      4 => 0.000000,
      5 => 0.000000,
      6 => 0.000000,
      7 => 0.000000 );

end package TFL_FAST_USER_IP_CONF_PUBLIC_p;
