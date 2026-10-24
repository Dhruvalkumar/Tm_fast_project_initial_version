library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.TFL_FAST_USER_PUBLIC1_p.all;
use work.TFL_FAST_USER_PUBLIC2_p.all;
use work.TFL_FAST_USER_IP_CONF_p.all;
use work.TFL_FAST_USER_IP_CONF_PUBLIC_p.all;

architecture TM_FAST_V07_URM14_Diagnostics of TFL_FAST_USER_e is

  ----------------------------------------------------------------------------
  -- Local subtypes (Quartus-friendly)
  ----------------------------------------------------------------------------
  subtype byte_t  is std_logic_vector(7 downto 0);
  subtype dword_t is std_logic_vector(31 downto 0);
  subtype u16_t   is unsigned(15 downto 0);
  subtype u32_t   is unsigned(31 downto 0);

  constant U32_ZERO : u32_t := to_unsigned(0, 32);
  constant U32_MAX  : u32_t := to_unsigned(16#FFFF_FFFF#, 32);
  constant U16_ZERO : u16_t := to_unsigned(0, 16);
  constant U16_MAX  : u16_t := to_unsigned(16#FFFF#, 16);

  ----------------------------------------------------------------------------
  -- Helpers / buffers
  ----------------------------------------------------------------------------
  constant RX_BUF_MAX : natural := 16;
  type rx_buf_t is array (0 to RX_BUF_MAX-1) of byte_t;

  function pack4(b0, b1, b2, b3 : byte_t) return dword_t is
    variable w : dword_t;
  begin
    w(7 downto 0)    := b0;
    w(15 downto 8)   := b1;
    w(23 downto 16)  := b2;
    w(31 downto 24)  := b3;
    return w;
  end function;

  function inc_sat_u16(x : u16_t) return u16_t is
  begin
    if x = U16_MAX then
      return x;
    else
      return x + 1;
    end if;
  end function;

  function abs_diff_u16(a, b : u16_t) return u16_t is
  begin
    if a >= b then
      return a - b;
    else
      return b - a;
    end if;
  end function;

  function iir_step_u16(filt, raw : u16_t) return u16_t is
    variable f_s : signed(17 downto 0);
    variable r_s : signed(17 downto 0);
    variable d_s : signed(17 downto 0);
    variable n_s : signed(17 downto 0);
  begin
    f_s := signed(resize(filt, 18));
    r_s := signed(resize(raw, 18));
    d_s := shift_right(r_s - f_s, 2); -- alpha = 1/4
    n_s := f_s + d_s;

    if n_s < to_signed(0, 18) then
      return U16_ZERO;
    elsif n_s > to_signed(65535, 18) then
      return U16_MAX;
    else
      return unsigned(n_s(15 downto 0));
    end if;
  end function;

  -- ms -> ticks @ 50 MHz without a multiplier:
  -- 50_000 = 2^15 + 2^14 + 2^9 + 2^8 + 2^6 + 2^4
  function ms_to_ticks(ms_u16 : u16_t) return u32_t is
    variable ms32 : u32_t := resize(ms_u16, 32);
    variable acc  : unsigned(32 downto 0) := (others => '0');
  begin
    acc := acc
      + ('0' & shift_left(ms32, 15))
      + ('0' & shift_left(ms32, 14))
      + ('0' & shift_left(ms32, 9))
      + ('0' & shift_left(ms32, 8))
      + ('0' & shift_left(ms32, 6))
      + ('0' & shift_left(ms32, 4));
    return acc(31 downto 0);
  end function;

  ----------------------------------------------------------------------------
  -- Contract constants
  ----------------------------------------------------------------------------
  constant MAGIC_V07 : dword_t := x"56303730"; -- "V070"
  constant MAGIC_V06 : dword_t := x"56303630"; -- "V060" accepted during development only
  constant MAGIC_V05 : dword_t := x"56303530"; -- "V050" kept only for fallback/debug recognition

  constant DEFAULT_SLAVE_ID   : byte_t := x"0C";
  constant DEFAULT_POLL_MS    : u16_t  := to_unsigned(1500, 16);
  constant DEFAULT_WAIT_MS    : u16_t  := to_unsigned(300, 16);
  constant DEFAULT_TIMEOUT_MS : u16_t  := to_unsigned(50, 16);

  constant HYST_RAW10  : u16_t := to_unsigned(500, 16); -- 50mm*10 (0.1mm units)
  constant COMM_FAIL_N : unsigned(7 downto 0) := to_unsigned(3, 8);

  constant DEFAULT_MAX_JUMP_RAW10 : u16_t := to_unsigned(1000, 16); -- 100.0 mm
  constant DEFAULT_STUCK_TIME_MS  : u16_t := to_unsigned(5000, 16); -- 5 s
  constant DEFAULT_FILTER_SHIFT   : u16_t := to_unsigned(2, 16);    -- fixed alpha=1/4 in this V07 build
  constant DEFAULT_QUALITY_WINDOW : u16_t := to_unsigned(10, 16);

  -- V07 diagnostic states exposed in FB_STATUS0[7:0] and RD_REC102.DW1[7:0]
  constant ST_IDLE              : byte_t := x"00";
  constant ST_WAIT_REC          : byte_t := x"01";
  constant ST_REAL_POLLING      : byte_t := x"02";
  constant ST_SIMULATION_ACTIVE : byte_t := x"03";
  constant ST_VALID_DATA        : byte_t := x"04";
  constant ST_INVALID_VALUE     : byte_t := x"05";
  constant ST_TIMEOUT_FAULT     : byte_t := x"06";
  constant ST_CRC_FAULT         : byte_t := x"07";
  constant ST_STALE_DATA        : byte_t := x"08";
  constant ST_COMM_FAULT        : byte_t := x"09";
  constant ST_UNSTABLE_SIGNAL   : byte_t := x"0A";
  constant ST_STUCK_VALUE       : byte_t := x"0B";
  constant ST_OUTPUT_DISABLED   : byte_t := x"0C";

  ----------------------------------------------------------------------------
  -- CRC polynomial (Modbus CRC16, LSB-first)
  ----------------------------------------------------------------------------
  constant CRC_POLY : u16_t := to_unsigned(16#A001#, 16);

  ----------------------------------------------------------------------------
  -- CTRL_IF (registered once to reduce fanout)
  ----------------------------------------------------------------------------
  signal ctrl_dw0_r : dword_t := (others => '0');
  signal ctrl_dw1_r : dword_t := (others => '0');
  signal ctrl_dw2_r : dword_t := (others => '0');

  signal ctrl_flags      : std_logic_vector(7 downto 0);
  signal flag_use_rec101 : std_logic;
  signal ctrl_param_seq  : std_logic_vector(15 downto 0);
  signal ctrl_mode       : std_logic_vector(7 downto 0);

  ----------------------------------------------------------------------------
  -- Commit path (WR_REC101)
  ----------------------------------------------------------------------------
  signal rec_valid      : std_logic := '0';
  signal committed_dw0  : dword_t := (others => '0');
  signal committed_dw1  : dword_t := (others => '0');
  signal committed_dw2  : dword_t := (others => '0');
  signal committed_dw3  : dword_t := (others => '0'); -- slave_id in [31..16]
  signal committed_dw4  : dword_t := (others => '0'); -- V07 diagnostics: max_jump/filter
  signal committed_dw5  : dword_t := (others => '0'); -- V07 diagnostics: stuck/quality window
  signal committed_dw6  : dword_t := (others => '0'); -- reserved

  signal bad_magic_cnt : u16_t := (others => '0');
  signal commit_cnt    : u16_t := (others => '0');

  ----------------------------------------------------------------------------
  -- Active params (CTRL_IF or committed) - registered for stability
  ----------------------------------------------------------------------------
  signal active_dw0_s : dword_t := (others => '0');
  signal active_dw1_s : dword_t := (others => '0');
  signal active_dw2_s : dword_t := (others => '0');
  signal active_dw3_s : dword_t := (others => '0');
  signal active_dw4_s : dword_t := (others => '0');
  signal active_dw5_s : dword_t := (others => '0');
  signal active_dw6_s : dword_t := (others => '0');

  signal active_dw0 : dword_t := (others => '0');
  signal active_dw1 : dword_t := (others => '0');
  signal active_dw2 : dword_t := (others => '0');
  signal active_dw3 : dword_t := (others => '0');
  signal active_dw4 : dword_t := (others => '0');
  signal active_dw5 : dword_t := (others => '0');
  signal active_dw6 : dword_t := (others => '0');

  signal active_param_seq   : std_logic_vector(15 downto 0);
  signal active_mode        : std_logic_vector(7 downto 0);
  signal active_flags       : std_logic_vector(7 downto 0);
  signal active_enable_run  : std_logic;
  signal active_enable_out  : std_logic;
  signal active_clear_cnt   : std_logic;
  signal opt_write_phase_en     : std_logic;
  signal simulation_enable      : std_logic;
  signal fault_injection_enable : std_logic;
  signal filter_enable          : std_logic;

  signal clear_cnt_prev  : std_logic := '0';
  signal clear_cnt_pulse : std_logic := '0';

  ----------------------------------------------------------------------------
  -- Parameterized comm + control values
  ----------------------------------------------------------------------------
  signal slave_id_b      : byte_t := DEFAULT_SLAVE_ID;
  signal timeout_ms_u16  : u16_t  := DEFAULT_TIMEOUT_MS;
  signal poll_ms_u16     : u16_t  := DEFAULT_POLL_MS;
  signal wait_ms_u16     : u16_t  := DEFAULT_WAIT_MS;

  signal threshold_mm_u16          : u16_t := (others => '0');
  signal threshold_raw10_u16       : u16_t := (others => '0'); -- mm*10 (0.1mm units)
  signal threshold_clear_raw10_u16 : u16_t := (others => '0'); -- + hysteresis

  signal poll_ticks_target    : u32_t := (others => '0');
  signal wait_ticks_target    : u32_t := (others => '0');
  signal rx_timeout_ticks_tgt : u32_t := (others => '0');
  signal max_age_ticks        : u32_t := (others => '0');

  -- V07 diagnostic parameters from WR_REC101.DW5/DW6 or defaults
  signal filter_shift_u16      : u16_t := DEFAULT_FILTER_SHIFT;
  signal max_jump_raw10_u16    : u16_t := DEFAULT_MAX_JUMP_RAW10;
  signal stuck_time_ms_u16     : u16_t := DEFAULT_STUCK_TIME_MS;
  signal quality_window_u16    : u16_t := DEFAULT_QUALITY_WINDOW;
  signal stuck_ticks_target    : u32_t := (others => '0');

  ----------------------------------------------------------------------------
  -- Status published
  ----------------------------------------------------------------------------
  signal state_b        : byte_t := ST_IDLE;
  signal error_code_b   : byte_t := x"00";
  signal sensor_quality : unsigned(7 downto 0) := to_unsigned(0, 8);
  signal output_state_b : byte_t := x"00";

  ----------------------------------------------------------------------------
  -- Heartbeat
  ----------------------------------------------------------------------------
  signal hb_div    : unsigned(23 downto 0) := (others => '0');
  signal heartbeat : u32_t := (others => '0');

  ----------------------------------------------------------------------------
  -- IO regs
  ----------------------------------------------------------------------------
  signal fb_if_r   : DWORD_VECTOR((FB_IF_DWORD_SIZE - 1) downto 0) := (others => (others => '0'));
  signal rd_rec_r  : DWORD_VECTOR((RD_REC_DWORD_MAX_SIZE - 1) downto 0) := (others => (others => '0'));
  signal rd_busy_r : std_logic := '0';

  signal dq_r       : std_logic_vector((DQ_QUANTITY - 1) downto 0) := (others => '0');
  signal rs485_tx_r : std_logic_vector((RS485_QUANTITY - 1) downto 0) := (others => '1');
  signal rs485_oe_r : std_logic_vector((RS485_QUANTITY - 1) downto 0) := (others => '0');

  ----------------------------------------------------------------------------
  -- UART timing @ 50 MHz / 19200 baud
  ----------------------------------------------------------------------------
  constant BIT_TICKS      : integer := 2604;
  constant HALF_BIT_TICKS : integer := BIT_TICKS / 2;

  ----------------------------------------------------------------------------
  -- Poll timing
  ----------------------------------------------------------------------------
  signal poll_cnt   : u32_t := (others => '0');
  signal start_poll : std_logic := '0';

  ----------------------------------------------------------------------------
  -- TX engine (CH0) with sequential CRC update (timing-friendly)
  ----------------------------------------------------------------------------
  type tx_state_t is (
    TX_IDLE, TX_START, TX_DATA, TX_STOP,
    TX_POSTBYTE, TX_CRC_LOAD, TX_CRC_SHIFT,
    TX_GUARD
  );
  signal tx_state    : tx_state_t := TX_IDLE;
  signal tx_done     : std_logic := '0';

  signal tx_byte_idx : integer range 0 to 7 := 0;
  signal tx_bit_idx  : integer range 0 to 7 := 0;
  signal tx_shift    : byte_t := (others => '0');
  signal tx_tick_cnt : integer range 0 to BIT_TICKS := 0;

  signal tx_count : u16_t := (others => '0');

  type tx_sel_t is (SEL_WRITE, SEL_READ);
  signal tx_sel : tx_sel_t := SEL_WRITE;

  -- TX CRC sequencer
  signal tx_crc_reg  : u16_t := x"FFFF";
  signal tx_crc_work : u16_t := x"0000";
  signal tx_crc_byte : byte_t := (others => '0');
  signal tx_crc_bit  : integer range 0 to 7 := 0;

  function tx_payload_byte(sel : tx_sel_t; idx : integer) return byte_t is
  begin
    -- idx in 0..5 for payload bytes (CRC appended later)
    if idx = 1 then
      if sel = SEL_WRITE then return x"06"; else return x"03"; end if;
    elsif idx = 2 then
      return x"00";
    elsif idx = 3 then
      if sel = SEL_WRITE then return x"08"; else return x"05"; end if;
    elsif idx = 4 then
      return x"00";
    elsif idx = 5 then
      if sel = SEL_WRITE then return x"0C"; else return x"02"; end if;
    else
      return x"00";
    end if;
  end function;

  function tx_byte_at(sel : tx_sel_t; sid : byte_t; idx : integer; crc : u16_t) return byte_t is
    variable crc_slv : std_logic_vector(15 downto 0);
  begin
    if idx = 0 then
      return sid;
    elsif idx >= 1 and idx <= 5 then
      return tx_payload_byte(sel, idx);
    elsif idx = 6 then
      crc_slv := std_logic_vector(crc);
      return crc_slv(7 downto 0);
    else
      crc_slv := std_logic_vector(crc);
      return crc_slv(15 downto 8);
    end if;
  end function;

  ----------------------------------------------------------------------------
  -- RX engine
  ----------------------------------------------------------------------------
  type rx_mode_t is (RX_FIXED8, RX_MB_RESP);
  signal rx_mode : rx_mode_t := RX_FIXED8;

  type rx_state_t is (RX_IDLE, RX_START, RX_DATA, RX_STOP);
  signal rx_state : rx_state_t := RX_IDLE;

  signal rx_arm      : std_logic := '0';
  signal rx_tick_cnt : integer range 0 to BIT_TICKS := 0;
  signal rx_bit_idx  : integer range 0 to 7 := 0;
  signal rx_shift    : byte_t := (others => '0');

  signal rx_buf    : rx_buf_t := (others => (others => '0'));
  signal rx_len    : integer range 0 to RX_BUF_MAX := 0;
  signal rx_target : integer range 0 to RX_BUF_MAX := 0;

  signal rx_done    : std_logic := '0';
  signal rx_timeout : std_logic := '0';

  signal rx_timeout_cnt : u32_t := (others => '0');

  ----------------------------------------------------------------------------
  -- Diagnostics
  ----------------------------------------------------------------------------
  signal rx_ok_count      : u16_t := (others => '0');
  signal rx_timeout_count : u16_t := (others => '0');
  signal rx_crc_bad_count : u16_t := (others => '0');

  signal last_rx_ok   : std_logic := '0';
  signal last_timeout : std_logic := '0';
  signal last_crc_bad : std_logic := '0';

  signal last_rx_len  : unsigned(5 downto 0) := (others => '0');

  signal dist_raw_u16 : std_logic_vector(15 downto 0) := x"FFFF";
  signal temp_raw_u16 : std_logic_vector(15 downto 0) := x"FFFF";

  signal comm_error_latched : byte_t := x"00";

  ----------------------------------------------------------------------------
  -- V06/V07 control health + behavior
  ----------------------------------------------------------------------------
  signal meas_valid     : std_logic := '0';
  signal meas_age_ticks : u32_t := (others => '0');
  signal meas_stale     : std_logic := '0';

  signal consec_fail : unsigned(7 downto 0) := (others => '0');
  signal comm_fault  : std_logic := '0';

  signal obstacle_latched : std_logic := '0';
  signal data_ok          : std_logic := '0';

  ----------------------------------------------------------------------------
  -- V07 simulation + signal-quality processing
  ----------------------------------------------------------------------------
  signal poll_good_pulse      : std_logic := '0';
  signal poll_fail_pulse      : std_logic := '0';
  signal real_poll_good_pulse : std_logic := '0';
  signal real_poll_fail_pulse : std_logic := '0';
  signal real_invalid_pulse   : std_logic := '0';

  signal sim_dist_raw10       : u16_t := to_unsigned(10000, 16); -- 1000.0 mm
  signal sim_temp_raw10       : u16_t := to_unsigned(250, 16);   -- 25.0 C
  signal sim_tick_cnt         : u32_t := (others => '0');
  signal sim_sample_pulse     : std_logic := '0';
  signal sim_good_pulse       : std_logic := '0';
  signal sim_fail_pulse       : std_logic := '0';
  signal sim_invalid_pulse    : std_logic := '0';
  signal sim_timeout_pulse    : std_logic := '0';
  signal sim_timeout_fault    : std_logic := '0';
  signal sim_step_toggle      : std_logic := '0';

  signal invalid_count        : u16_t := (others => '0');
  signal unstable_count       : u16_t := (others => '0');
  signal stuck_count          : u16_t := (others => '0');

  signal invalid_fault        : std_logic := '0';
  signal unstable_fault       : std_logic := '0';
  signal stuck_fault          : std_logic := '0';

  signal proc_dist_raw_u16    : std_logic_vector(15 downto 0) := x"FFFF";
  signal proc_temp_raw_u16    : std_logic_vector(15 downto 0) := x"FFFF";
  signal filtered_dist_raw10  : u16_t := (others => '0');
  signal filter_initialized   : std_logic := '0';
  signal last_valid_raw10     : u16_t := (others => '0');
  signal last_sample_raw10    : u16_t := (others => '0');
  signal stuck_timer_ticks    : u32_t := (others => '0');

  signal simulation_active    : std_logic := '0';

  ----------------------------------------------------------------------------
  -- CRC checker FSM (sequential bit-by-bit, timing-friendly)
  ----------------------------------------------------------------------------
  signal rx_buf_snap : rx_buf_t := (others => (others => '0'));
  signal rx_len_snap : integer range 0 to RX_BUF_MAX := 0;

  signal crc_start : std_logic := '0';
  signal crc_done  : std_logic := '0';
  signal crc_ok    : std_logic := '0';

  signal crc_active  : std_logic := '0';
  signal crc_len_reg : integer range 0 to RX_BUF_MAX := 0;
  signal crc_idx     : integer range 0 to RX_BUF_MAX := 0;

  signal rx_crc_lo_snap : byte_t := (others => '0');
  signal rx_crc_hi_snap : byte_t := (others => '0');

  signal crc_reg  : u16_t := x"FFFF";
  signal crc_work : u16_t := x"0000";
  signal crc_bit  : integer range 0 to 7 := 0;

  type crc_state_t is (CRC_IDLE, CRC_LOAD, CRC_SHIFT);
  signal crc_state : crc_state_t := CRC_IDLE;

  ----------------------------------------------------------------------------
  -- Modbus high-level FSM
  ----------------------------------------------------------------------------
  type mb_state_t is (
    MB_IDLE,
    MB_TX_WRITE, MB_RX_ECHO, MB_CRC_ECHO,
    MB_WAIT_MEAS,
    MB_TX_READ,  MB_RX_READ, MB_CRC_READ
  );
  signal mb_state : mb_state_t := MB_IDLE;

  signal wait_cnt : u32_t := (others => '0');

begin

  simulation_active <= simulation_enable and active_enable_run;
  poll_good_pulse   <= real_poll_good_pulse or sim_good_pulse;
  poll_fail_pulse   <= real_poll_fail_pulse or sim_fail_pulse;

  ----------------------------------------------------------------------------
  -- Drive outputs
  ----------------------------------------------------------------------------
  FB_IF       <= fb_if_r;
  RD_REC      <= rd_rec_r;
  RD_REC_BUSY <= rd_busy_r;

  DQ       <= dq_r;
  RS485_TX <= rs485_tx_r;
  RS485_OE <= rs485_oe_r;

  ----------------------------------------------------------------------------
  -- Register CTRL_IF once (reduces combinational fanout)
  ----------------------------------------------------------------------------
  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        ctrl_dw0_r <= (others => '0');
        ctrl_dw1_r <= (others => '0');
        ctrl_dw2_r <= (others => '0');
      else
        if CTRL_IF_DWORD_SIZE > 0 then ctrl_dw0_r <= CTRL_IF(0); end if;
        if CTRL_IF_DWORD_SIZE > 1 then ctrl_dw1_r <= CTRL_IF(1); end if;
        if CTRL_IF_DWORD_SIZE > 2 then ctrl_dw2_r <= CTRL_IF(2); end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- CTRL unpack (from registered CTRL)
  ----------------------------------------------------------------------------
  ctrl_param_seq  <= ctrl_dw1_r(31 downto 16);
  ctrl_mode       <= ctrl_dw1_r(15 downto 8);
  ctrl_flags      <= ctrl_dw1_r(7 downto 0);
  flag_use_rec101 <= ctrl_flags(2);

  ----------------------------------------------------------------------------
  -- Active selection (combinational), then register once for stability
  ----------------------------------------------------------------------------
  active_dw0_s <= committed_dw0 when (flag_use_rec101='1' and rec_valid='1') else ctrl_dw0_r;
  active_dw1_s <= committed_dw1 when (flag_use_rec101='1' and rec_valid='1') else ctrl_dw1_r;
  active_dw2_s <= committed_dw2 when (flag_use_rec101='1' and rec_valid='1') else ctrl_dw2_r;
  active_dw3_s <= committed_dw3 when (flag_use_rec101='1' and rec_valid='1') else (others => '0');
  active_dw4_s <= committed_dw4 when (flag_use_rec101='1' and rec_valid='1') else (others => '0');
  active_dw5_s <= committed_dw5 when (flag_use_rec101='1' and rec_valid='1') else (others => '0');
  active_dw6_s <= committed_dw6 when (flag_use_rec101='1' and rec_valid='1') else (others => '0');

  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        active_dw0 <= (others => '0');
        active_dw1 <= (others => '0');
        active_dw2 <= (others => '0');
        active_dw3 <= (others => '0');
        active_dw4 <= (others => '0');
        active_dw5 <= (others => '0');
        active_dw6 <= (others => '0');
      else
        active_dw0 <= active_dw0_s;
        active_dw1 <= active_dw1_s;
        active_dw2 <= active_dw2_s;
        active_dw3 <= active_dw3_s;
        active_dw4 <= active_dw4_s;
        active_dw5 <= active_dw5_s;
        active_dw6 <= active_dw6_s;
      end if;
    end if;
  end process;

  active_param_seq   <= active_dw1(31 downto 16);
  active_mode        <= active_dw1(15 downto 8);
  active_flags       <= active_dw1(7 downto 0);
  opt_write_phase_en     <= active_flags(4);
  simulation_enable      <= active_flags(5);
  fault_injection_enable <= active_flags(6);
  filter_enable          <= active_flags(7);

  active_enable_run <= active_flags(0);
  active_enable_out <= active_flags(1);
  active_clear_cnt  <= active_flags(3);

  ----------------------------------------------------------------------------
  -- Clear counters pulse (edge detect)
  ----------------------------------------------------------------------------
  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        clear_cnt_prev  <= '0';
        clear_cnt_pulse <= '0';
      else
        clear_cnt_pulse <= (active_clear_cnt and (not clear_cnt_prev));
        clear_cnt_prev  <= active_clear_cnt;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Parameter decode + defaults
  ----------------------------------------------------------------------------
  process(active_dw0, active_dw2, active_dw3, active_dw4, active_dw5)
    variable sid16_v : u16_t;
    variable tmo_v   : u16_t;
    variable thr_v   : u16_t;
    variable pm_v    : u16_t;
    variable wm_v    : u16_t;

    variable sid_b_v : byte_t;

    variable thr10_w  : unsigned(19 downto 0);
    variable thr10_v  : u16_t;
    variable thrclr_w : unsigned(16 downto 0);
    variable thrclr_v : u16_t;

    variable poll_ticks_v : u32_t;
    variable wait_ticks_v : u32_t;
    variable tmo_ticks_v  : u32_t;

    variable age_sum_w : unsigned(32 downto 0);
    variable age_sum_v : u32_t;

    variable filt_v      : u16_t;
    variable max_jump_v  : u16_t;
    variable stuck_ms_v  : u16_t;
    variable qwin_v      : u16_t;
  begin
    tmo_v := unsigned(active_dw0(31 downto 16));
    thr_v := unsigned(active_dw0(15 downto 0));

    pm_v  := unsigned(active_dw2(31 downto 16));
    wm_v  := unsigned(active_dw2(15 downto 0));

    sid16_v := unsigned(active_dw3(31 downto 16));

    if sid16_v = 0 then
      sid_b_v := DEFAULT_SLAVE_ID;
    else
      sid_b_v := std_logic_vector(sid16_v(7 downto 0));
    end if;

    if tmo_v = 0 then tmo_v := DEFAULT_TIMEOUT_MS; end if;
    if pm_v  = 0 then pm_v  := DEFAULT_POLL_MS;    end if;
    if wm_v  = 0 then wm_v  := DEFAULT_WAIT_MS;    end if;

    filt_v     := unsigned(active_dw4(15 downto 0));
    max_jump_v := unsigned(active_dw4(31 downto 16));
    stuck_ms_v := unsigned(active_dw5(15 downto 0));
    qwin_v     := unsigned(active_dw5(31 downto 16));

    if filt_v = 0 then filt_v := DEFAULT_FILTER_SHIFT; end if;
    if max_jump_v = 0 then max_jump_v := DEFAULT_MAX_JUMP_RAW10; end if;
    if stuck_ms_v = 0 then stuck_ms_v := DEFAULT_STUCK_TIME_MS; end if;
    if qwin_v = 0 then qwin_v := DEFAULT_QUALITY_WINDOW; end if;


    -- thr*10 = (thr<<3) + (thr<<1)
    thr10_w := shift_left(resize(thr_v, 20), 3) + shift_left(resize(thr_v, 20), 1);
    if thr10_w(19 downto 16) /= "0000" then
      thr10_v := U16_MAX;
    else
      thr10_v := thr10_w(15 downto 0);
    end if;

    thrclr_w := resize(thr10_v, 17) + resize(HYST_RAW10, 17);
    if thrclr_w(16) = '1' then
      thrclr_v := U16_MAX;
    else
      thrclr_v := thrclr_w(15 downto 0);
    end if;

    poll_ticks_v := ms_to_ticks(pm_v);
    wait_ticks_v := ms_to_ticks(wm_v);
    tmo_ticks_v  := ms_to_ticks(tmo_v);

    -- max_age = poll + timeout + 2*wait, saturating to 32-bit
    age_sum_w := ('0' & poll_ticks_v) + ('0' & tmo_ticks_v) + ('0' & wait_ticks_v) + ('0' & wait_ticks_v);
    if age_sum_w(32) = '1' then
      age_sum_v := U32_MAX;
    else
      age_sum_v := age_sum_w(31 downto 0);
    end if;

    slave_id_b                <= sid_b_v;
    timeout_ms_u16            <= tmo_v;
    poll_ms_u16               <= pm_v;
    wait_ms_u16               <= wm_v;

    threshold_mm_u16          <= thr_v;
    threshold_raw10_u16       <= thr10_v;
    threshold_clear_raw10_u16 <= thrclr_v;

    poll_ticks_target         <= poll_ticks_v;
    wait_ticks_target         <= wait_ticks_v;
    rx_timeout_ticks_tgt      <= tmo_ticks_v;
    max_age_ticks             <= age_sum_v;

    filter_shift_u16          <= filt_v;
    max_jump_raw10_u16        <= max_jump_v;
    stuck_time_ms_u16         <= stuck_ms_v;
    quality_window_u16        <= qwin_v;
    stuck_ticks_target        <= ms_to_ticks(stuck_ms_v);
  end process;

  ----------------------------------------------------------------------------
  -- Heartbeat
  ----------------------------------------------------------------------------
  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        hb_div    <= (others => '0');
        heartbeat <= (others => '0');
      else
        if hb_div = to_unsigned(5_000_000 - 1, hb_div'length) then
          hb_div    <= (others => '0');
          heartbeat <= heartbeat + 1;
        else
          hb_div <= hb_div + 1;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Commit (WR_REC101) + RD_REC_BUSY pulse on WR_REC_NEW
  ----------------------------------------------------------------------------
  process(CLK)
    variable w0 : dword_t;
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        rec_valid     <= '0';
        committed_dw0 <= (others => '0');
        committed_dw1 <= (others => '0');
        committed_dw2 <= (others => '0');
        committed_dw3 <= (others => '0');
        committed_dw4 <= (others => '0');
        committed_dw5 <= (others => '0');
        committed_dw6 <= (others => '0');
        bad_magic_cnt <= (others => '0');
        commit_cnt    <= (others => '0');
        rd_busy_r     <= '0';
      else
        rd_busy_r <= '0';

        if clear_cnt_pulse = '1' then
          bad_magic_cnt <= (others => '0');
          commit_cnt    <= (others => '0');
        end if;

        if WR_REC_NEW = '1' then
          rd_busy_r <= '1';
          w0 := WR_REC(0);

          if (w0 = MAGIC_V07) or (w0 = MAGIC_V06) then
            -- Development phase accepts V06/V07 records. Final strict mode should accept MAGIC_V07 only.
            committed_dw0 <= WR_REC(1);
            committed_dw1 <= WR_REC(2);
            committed_dw2 <= WR_REC(3);
            committed_dw3 <= WR_REC(4);
            committed_dw4 <= WR_REC(5);
            committed_dw5 <= WR_REC(6);
            committed_dw6 <= WR_REC(7);
            rec_valid     <= '1';
            commit_cnt    <= commit_cnt + 1;
          else
            bad_magic_cnt <= bad_magic_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Poll timer
  ----------------------------------------------------------------------------
  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        poll_cnt   <= (others => '0');
        start_poll <= '0';
      else
        start_poll <= '0';

        if (active_enable_run = '1') and not (flag_use_rec101='1' and rec_valid='0') then
          if poll_cnt >= poll_ticks_target then
            poll_cnt   <= (others => '0');
            start_poll <= '1';
          else
            poll_cnt <= poll_cnt + 1;
          end if;
        else
          poll_cnt <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- TX engine (CH0) with sequential CRC update
  ----------------------------------------------------------------------------
  process(CLK)
    variable next_work : u16_t;
    variable bnext     : byte_t;
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        tx_state    <= TX_IDLE;
        tx_done     <= '0';
        tx_byte_idx <= 0;
        tx_bit_idx  <= 0;
        tx_shift    <= (others => '0');
        tx_tick_cnt <= 0;

        rs485_tx_r <= (others => '1');
        rs485_oe_r <= (others => '0');

        tx_count   <= (others => '0');

        tx_crc_reg  <= x"FFFF";
        tx_crc_work <= x"0000";
        tx_crc_byte <= (others => '0');
        tx_crc_bit  <= 0;

      else
        tx_done <= '0';

        case tx_state is
          when TX_IDLE =>
            rs485_tx_r(0) <= '1';
            rs485_oe_r(0) <= '0';

            if (mb_state = MB_TX_WRITE) or (mb_state = MB_TX_READ) then
              tx_crc_reg  <= x"FFFF";
              tx_byte_idx <= 0;
              tx_bit_idx  <= 0;

              bnext    := tx_byte_at(tx_sel, slave_id_b, 0, x"FFFF");
              tx_shift <= bnext;

              rs485_oe_r(0) <= '1';
              rs485_tx_r(0) <= '0'; -- start bit
              tx_tick_cnt   <= BIT_TICKS - 1;
              tx_state      <= TX_START;

              tx_count <= tx_count + 1;
            end if;

          when TX_START =>
            if tx_tick_cnt = 0 then
              tx_tick_cnt   <= BIT_TICKS - 1;
              tx_bit_idx    <= 0;
              rs485_tx_r(0) <= tx_shift(0);
              tx_state      <= TX_DATA;
            else
              tx_tick_cnt <= tx_tick_cnt - 1;
            end if;

          when TX_DATA =>
            if tx_tick_cnt = 0 then
              tx_tick_cnt <= BIT_TICKS - 1;
              if tx_bit_idx = 7 then
                rs485_tx_r(0) <= '1'; -- stop bit
                tx_state      <= TX_STOP;
              else
                tx_bit_idx    <= tx_bit_idx + 1;
                rs485_tx_r(0) <= tx_shift(tx_bit_idx + 1);
              end if;
            else
              tx_tick_cnt <= tx_tick_cnt - 1;
            end if;

          when TX_STOP =>
            if tx_tick_cnt = 0 then
              tx_state <= TX_POSTBYTE;
            else
              tx_tick_cnt <= tx_tick_cnt - 1;
            end if;

          when TX_POSTBYTE =>
            -- After a byte is fully sent (incl stop), optionally update CRC for bytes 0..5
            rs485_tx_r(0) <= '1'; -- keep line idle-high while we do CRC work

            if tx_byte_idx <= 5 then
              tx_crc_byte <= tx_shift;
              tx_state    <= TX_CRC_LOAD;
            else
              -- no CRC update needed for bytes 6/7
              if tx_byte_idx = 7 then
                tx_tick_cnt <= BIT_TICKS - 1;
                tx_state    <= TX_GUARD;
              else
                -- next byte
                tx_byte_idx <= tx_byte_idx + 1;
                bnext       := tx_byte_at(tx_sel, slave_id_b, tx_byte_idx + 1, tx_crc_reg);
                tx_shift    <= bnext;

                rs485_tx_r(0) <= '0'; -- start bit
                rs485_oe_r(0) <= '1';
                tx_tick_cnt   <= BIT_TICKS - 1;
                tx_state      <= TX_START;
              end if;
            end if;

          when TX_CRC_LOAD =>
            -- crc_work = crc_reg xor byte
            tx_crc_work <= tx_crc_reg xor resize(unsigned(tx_crc_byte), 16);
            tx_crc_bit  <= 0;
            tx_state    <= TX_CRC_SHIFT;

          when TX_CRC_SHIFT =>
            next_work := shift_right(tx_crc_work, 1);
            if tx_crc_work(0) = '1' then
              next_work := next_work xor CRC_POLY;
            end if;

            tx_crc_work <= next_work;

            if tx_crc_bit = 7 then
              -- commit updated crc for this byte
              tx_crc_reg <= next_work;

              if tx_byte_idx = 7 then
                tx_tick_cnt <= BIT_TICKS - 1;
                tx_state    <= TX_GUARD;
              else
                -- advance to next byte
                tx_byte_idx <= tx_byte_idx + 1;
                bnext       := tx_byte_at(tx_sel, slave_id_b, tx_byte_idx + 1, next_work);
                tx_shift    <= bnext;

                rs485_tx_r(0) <= '0'; -- start bit
                rs485_oe_r(0) <= '1';
                tx_tick_cnt   <= BIT_TICKS - 1;
                tx_state      <= TX_START;
              end if;
            else
              tx_crc_bit <= tx_crc_bit + 1;
            end if;

          when TX_GUARD =>
            if tx_tick_cnt = 0 then
              rs485_tx_r(0) <= '1';
              rs485_oe_r(0) <= '0';
              tx_state      <= TX_IDLE;
              tx_done       <= '1';
            else
              tx_tick_cnt <= tx_tick_cnt - 1;
            end if;

        end case;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- RX engine (timeout parameterized)
  ----------------------------------------------------------------------------
  process(CLK)
    variable func_b    : byte_t;
    variable bytecount : integer;
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        rx_state       <= RX_IDLE;
        rx_len         <= 0;
        rx_target      <= 0;
        rx_tick_cnt    <= 0;
        rx_bit_idx     <= 0;
        rx_shift       <= (others => '0');

        rx_done        <= '0';
        rx_timeout     <= '0';
        rx_timeout_cnt <= (others => '0');

        rx_buf         <= (others => (others => '0'));
      else
        rx_done    <= '0';
        rx_timeout <= '0';

        if rx_arm = '0' then
          rx_state       <= RX_IDLE;
          rx_timeout_cnt <= (others => '0');
        else
          if rx_timeout_cnt < rx_timeout_ticks_tgt then
            rx_timeout_cnt <= rx_timeout_cnt + 1;
          else
            rx_timeout_cnt <= (others => '0');
            rx_timeout     <= '1';
            rx_state       <= RX_IDLE;
          end if;

          case rx_state is
            when RX_IDLE =>
              rx_len     <= 0;
              rx_bit_idx <= 0;

              if rx_mode = RX_FIXED8 then
                rx_target <= 8;
              else
                rx_target <= 0;
              end if;

              if RS485_RX(0) = '0' then
                rx_tick_cnt <= HALF_BIT_TICKS - 1;
                rx_state    <= RX_START;
              end if;

            when RX_START =>
              if rx_tick_cnt = 0 then
                rx_tick_cnt <= BIT_TICKS - 1;
                rx_bit_idx  <= 0;
                rx_shift(0) <= RS485_RX(0);
                rx_state    <= RX_DATA;
              else
                rx_tick_cnt <= rx_tick_cnt - 1;
              end if;

            when RX_DATA =>
              if rx_tick_cnt = 0 then
                rx_tick_cnt <= BIT_TICKS - 1;
                if rx_bit_idx = 7 then
                  rx_state <= RX_STOP;
                else
                  rx_bit_idx <= rx_bit_idx + 1;
                  rx_shift(rx_bit_idx + 1) <= RS485_RX(0);
                end if;
              else
                rx_tick_cnt <= rx_tick_cnt - 1;
              end if;

            when RX_STOP =>
              if rx_tick_cnt = 0 then
                if rx_len < integer(RX_BUF_MAX) then
                  rx_buf(rx_len) <= rx_shift;
                  rx_len <= rx_len + 1;
                end if;

                if rx_mode = RX_MB_RESP then
                  if rx_len = 1 then
                    func_b := rx_shift;
                    if func_b(7) = '1' then
                      rx_target <= 5; -- exception: sid, func, code, crcLo, crcHi
                    end if;
                  elsif rx_len = 2 then
                    if rx_buf(1) = x"03" then
                      bytecount := to_integer(unsigned(rx_shift));
                      if (3 + bytecount + 2) <= integer(RX_BUF_MAX) then
                        rx_target <= 3 + bytecount + 2;
                      else
                        rx_target <= integer(RX_BUF_MAX);
                      end if;
                    end if;
                  end if;
                end if;

                if (rx_mode = RX_FIXED8 and (rx_len + 1) >= 8) or
                   (rx_mode = RX_MB_RESP and rx_target /= 0 and (rx_len + 1) >= rx_target) then
                  rx_done <= '1';
                  rx_state <= RX_IDLE;
                  rx_timeout_cnt <= (others => '0');
                else
                  rx_state <= RX_IDLE;
                end if;

              else
                rx_tick_cnt <= rx_tick_cnt - 1;
              end if;
          end case;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- CRC checker FSM (sequential bit-by-bit)
  ----------------------------------------------------------------------------
  process(CLK)
    variable lo_b    : byte_t;
    variable hi_b    : byte_t;
    variable next_w  : u16_t;
    variable crc_slv : std_logic_vector(15 downto 0);
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        crc_reg    <= x"FFFF";
        crc_work   <= x"0000";
        crc_idx    <= 0;
        crc_bit    <= 0;
        crc_done   <= '0';
        crc_ok     <= '0';
        crc_active <= '0';
        crc_state  <= CRC_IDLE;
      else
        crc_done <= '0';

        if crc_start = '1' then
          crc_reg    <= x"FFFF";
          crc_idx    <= 0;
          crc_bit    <= 0;
          crc_ok     <= '0';
          crc_active <= '1';
          crc_state  <= CRC_LOAD;

        elsif crc_active = '1' then
          case crc_state is
            when CRC_LOAD =>
              if crc_idx < crc_len_reg then
                crc_work  <= crc_reg xor resize(unsigned(rx_buf_snap(crc_idx)), 16);
                crc_bit   <= 0;
                crc_state <= CRC_SHIFT;
              else
                crc_slv := std_logic_vector(crc_reg);
                lo_b := crc_slv(7 downto 0);
                hi_b := crc_slv(15 downto 8);

                if (lo_b = rx_crc_lo_snap) and (hi_b = rx_crc_hi_snap) then
                  crc_ok <= '1';
                else
                  crc_ok <= '0';
                end if;

                crc_done   <= '1';
                crc_active <= '0';
                crc_state  <= CRC_IDLE;
              end if;

            when CRC_SHIFT =>
              next_w := shift_right(crc_work, 1);
              if crc_work(0) = '1' then
                next_w := next_w xor CRC_POLY;
              end if;

              crc_work <= next_w;

              if crc_bit = 7 then
                crc_reg   <= next_w;
                crc_idx   <= crc_idx + 1;
                crc_state <= CRC_LOAD;
              else
                crc_bit <= crc_bit + 1;
              end if;

            when others =>
              crc_state <= CRC_IDLE;
          end case;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Modbus high-level FSM + counters + parsing
  ----------------------------------------------------------------------------
  process(CLK)
    variable dist_hi : byte_t;
    variable dist_lo : byte_t;
    variable temp_hi : byte_t;
    variable temp_lo : byte_t;
    variable len_eff : integer;
    variable d_raw   : std_logic_vector(15 downto 0);
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        mb_state <= MB_IDLE;

        tx_sel  <= SEL_WRITE;
        rx_arm  <= '0';
        rx_mode <= RX_FIXED8;

        wait_cnt <= (others => '0');

        rx_ok_count      <= (others => '0');
        rx_timeout_count <= (others => '0');
        rx_crc_bad_count <= (others => '0');

        last_rx_ok   <= '0';
        last_timeout <= '0';
        last_crc_bad <= '0';
        last_rx_len  <= (others => '0');

        dist_raw_u16 <= x"FFFF";
        temp_raw_u16 <= x"FFFF";
        comm_error_latched <= x"00";

        real_poll_good_pulse <= '0';
        real_poll_fail_pulse <= '0';
        real_invalid_pulse   <= '0';

        crc_start      <= '0';
        crc_len_reg    <= 0;
        rx_crc_lo_snap <= (others => '0');
        rx_crc_hi_snap <= (others => '0');
        rx_len_snap    <= 0;

        for i in 0 to RX_BUF_MAX-1 loop
          rx_buf_snap(i) <= (others => '0');
        end loop;

      else
        last_rx_ok   <= '0';
        last_timeout <= '0';
        last_crc_bad <= '0';
        real_invalid_pulse <= '0';

        real_poll_good_pulse <= '0';
        real_poll_fail_pulse <= '0';
        real_invalid_pulse   <= '0';

        crc_start <= '0';

        if clear_cnt_pulse = '1' then
          rx_ok_count      <= (others => '0');
          rx_timeout_count <= (others => '0');
          rx_crc_bad_count <= (others => '0');
        end if;

        case mb_state is
          when MB_IDLE =>
            rx_arm <= '0';

            if (start_poll = '1') and (simulation_enable = '0') then
              if opt_write_phase_en = '1' then
                tx_sel   <= SEL_WRITE;
                rx_mode  <= RX_FIXED8;
                mb_state <= MB_TX_WRITE;
              else
                tx_sel   <= SEL_READ;
                rx_mode  <= RX_MB_RESP;
                mb_state <= MB_TX_READ;
              end if;
            end if;

          when MB_TX_WRITE =>
            if tx_done = '1' then
              rx_mode  <= RX_FIXED8;
              rx_arm   <= '1';
              mb_state <= MB_RX_ECHO;
            end if;

          when MB_RX_ECHO =>
            if rx_timeout = '1' then
              rx_timeout_count   <= rx_timeout_count + 1;
              last_timeout       <= '1';
              comm_error_latched <= x"02";
              rx_arm   <= '0';
              wait_cnt <= (others => '0');
              mb_state <= MB_WAIT_MEAS;

            elsif rx_done = '1' then
              last_rx_len <= to_unsigned(rx_len, 6);

              for i in 0 to RX_BUF_MAX-1 loop
                rx_buf_snap(i) <= rx_buf(i);
              end loop;
              rx_len_snap <= rx_len;

              crc_len_reg    <= 6;
              rx_crc_lo_snap <= rx_buf(6);
              rx_crc_hi_snap <= rx_buf(7);

              crc_start <= '1';
              rx_arm    <= '0';
              mb_state  <= MB_CRC_ECHO;
            end if;

          when MB_CRC_ECHO =>
            if crc_done = '1' then
              if crc_ok = '0' then
                rx_crc_bad_count   <= rx_crc_bad_count + 1;
                last_crc_bad       <= '1';
                comm_error_latched <= x"03";
              end if;

              wait_cnt <= (others => '0');
              mb_state <= MB_WAIT_MEAS;
            end if;

          when MB_WAIT_MEAS =>
            rx_arm <= '0';
            if wait_cnt >= wait_ticks_target then
              tx_sel   <= SEL_READ;
              rx_mode  <= RX_MB_RESP;
              mb_state <= MB_TX_READ;
            else
              wait_cnt <= wait_cnt + 1;
            end if;

          when MB_TX_READ =>
            if tx_done = '1' then
              rx_mode  <= RX_MB_RESP;
              rx_arm   <= '1';
              mb_state <= MB_RX_READ;
            end if;

          when MB_RX_READ =>
            if rx_timeout = '1' then
              rx_timeout_count   <= rx_timeout_count + 1;
              last_timeout       <= '1';
              comm_error_latched <= x"02";
              rx_arm <= '0';
              real_poll_fail_pulse <= '1';
              mb_state <= MB_IDLE;

            elsif rx_done = '1' then
              last_rx_len <= to_unsigned(rx_len, 6);

              for i in 0 to RX_BUF_MAX-1 loop
                rx_buf_snap(i) <= rx_buf(i);
              end loop;
              rx_len_snap <= rx_len;

              len_eff := rx_len - 2;
              if len_eff < 0 then
                len_eff := 0;
              elsif len_eff > integer(RX_BUF_MAX) then
                len_eff := integer(RX_BUF_MAX);
              end if;

              crc_len_reg <= len_eff;

              if rx_len >= 2 then
                rx_crc_lo_snap <= rx_buf(rx_len - 2);
                rx_crc_hi_snap <= rx_buf(rx_len - 1);
              else
                rx_crc_lo_snap <= (others => '0');
                rx_crc_hi_snap <= (others => '0');
              end if;

              crc_start <= '1';
              rx_arm    <= '0';
              mb_state  <= MB_CRC_READ;
            end if;

          when MB_CRC_READ =>
            if crc_done = '1' then
              if (crc_ok = '1') then
                if (rx_len_snap >= 5) and (rx_buf_snap(0) = slave_id_b) then
                  if rx_buf_snap(1) = x"83" then
                    comm_error_latched <= x"04";
                    real_poll_fail_pulse <= '1';

                  elsif (rx_buf_snap(1) = x"03") and (rx_len_snap >= 9) and (rx_buf_snap(2) = x"04") then
                    dist_hi := rx_buf_snap(3);
                    dist_lo := rx_buf_snap(4);
                    temp_hi := rx_buf_snap(5);
                    temp_lo := rx_buf_snap(6);

                    d_raw := dist_hi & dist_lo;

                    if d_raw /= x"FFFF" then
                      dist_raw_u16 <= d_raw;
                      temp_raw_u16 <= temp_hi & temp_lo;

                      rx_ok_count <= rx_ok_count + 1;
                      last_rx_ok  <= '1';
                      comm_error_latched <= x"00";

                      real_poll_good_pulse <= '1';
                    else
                      comm_error_latched <= x"04";
                      real_invalid_pulse <= '1';
                      real_poll_fail_pulse <= '1';
                    end if;

                  else
                    comm_error_latched <= x"04";
                    real_poll_fail_pulse <= '1';
                  end if;
                else
                  comm_error_latched <= x"04";
                  real_poll_fail_pulse <= '1';
                end if;
              else
                rx_crc_bad_count   <= rx_crc_bad_count + 1;
                last_crc_bad       <= '1';
                comm_error_latched <= x"03";
                real_poll_fail_pulse    <= '1';
              end if;

              mb_state <= MB_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;


  ----------------------------------------------------------------------------
  -- V07 simulation generator (hardware-independent test source)
  ----------------------------------------------------------------------------
  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        sim_dist_raw10    <= to_unsigned(10000, 16);
        sim_temp_raw10    <= to_unsigned(250, 16);
        sim_tick_cnt      <= (others => '0');
        sim_sample_pulse  <= '0';
        sim_good_pulse    <= '0';
        sim_fail_pulse    <= '0';
        sim_invalid_pulse <= '0';
        sim_timeout_pulse <= '0';
        sim_timeout_fault <= '0';
        sim_step_toggle   <= '0';
      else
        sim_sample_pulse  <= '0';
        sim_good_pulse    <= '0';
        sim_fail_pulse    <= '0';
        sim_invalid_pulse <= '0';
        sim_timeout_pulse <= '0';

        if clear_cnt_pulse = '1' then
          sim_dist_raw10     <= to_unsigned(10000, 16);
          sim_tick_cnt       <= (others => '0');
          sim_timeout_fault  <= '0';
          sim_step_toggle    <= '0';
        elsif ((simulation_enable = '1') or (fault_injection_enable = '1')) and (start_poll = '1') then
          sim_sample_pulse <= '1';
          sim_tick_cnt <= sim_tick_cnt + 1;
          sim_timeout_fault <= '0';

          case active_mode is
            when x"02" => -- ramp
              sim_good_pulse <= '1';
              if sim_dist_raw10 >= to_unsigned(15000, 16) then
                sim_dist_raw10 <= to_unsigned(5000, 16);
              else
                sim_dist_raw10 <= sim_dist_raw10 + to_unsigned(100, 16);
              end if;

            when x"03" => -- step across threshold
              sim_good_pulse  <= '1';
              sim_step_toggle <= not sim_step_toggle;
              if sim_step_toggle = '0' then
                sim_dist_raw10 <= to_unsigned(15000, 16);
              else
                sim_dist_raw10 <= to_unsigned(8000, 16);
              end if;

            when x"04" => -- stuck value
              sim_good_pulse <= '1';
              sim_dist_raw10 <= to_unsigned(10000, 16);

            when x"05" => -- artificial jump/noise
              sim_good_pulse  <= '1';
              sim_step_toggle <= not sim_step_toggle;
              if sim_step_toggle = '0' then
                sim_dist_raw10 <= to_unsigned(10000, 16);
              else
                sim_dist_raw10 <= to_unsigned(14000, 16);
              end if;

            when x"06" => -- invalid measurement
              sim_dist_raw10    <= U16_MAX;
              sim_invalid_pulse <= '1';
              sim_fail_pulse    <= '1';

            when x"07" => -- timeout/no response simulation
              sim_timeout_pulse <= '1';
              sim_timeout_fault <= '1';
              sim_fail_pulse    <= '1';

            when others => -- default valid static sample
              sim_good_pulse <= '1';
              sim_dist_raw10 <= to_unsigned(10000, 16);
          end case;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- V07 measurement selection, filtering, unstable/stuck detection
  ----------------------------------------------------------------------------
  process(CLK)
    variable raw_v  : u16_t;
    variable temp_v : u16_t;
    variable jump_v : u16_t;
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        proc_dist_raw_u16   <= x"FFFF";
        proc_temp_raw_u16   <= x"FFFF";
        filtered_dist_raw10 <= (others => '0');
        filter_initialized  <= '0';
        last_valid_raw10    <= (others => '0');
        last_sample_raw10   <= (others => '0');
        stuck_timer_ticks   <= (others => '0');
        invalid_count       <= (others => '0');
        unstable_count      <= (others => '0');
        stuck_count         <= (others => '0');
        invalid_fault       <= '0';
        unstable_fault      <= '0';
        stuck_fault         <= '0';
      else
        if clear_cnt_pulse = '1' then
          proc_dist_raw_u16   <= x"FFFF";
          proc_temp_raw_u16   <= x"FFFF";
          filtered_dist_raw10 <= (others => '0');
          filter_initialized  <= '0';
          last_valid_raw10    <= (others => '0');
          last_sample_raw10   <= (others => '0');
          stuck_timer_ticks   <= (others => '0');
          invalid_count       <= (others => '0');
          unstable_count      <= (others => '0');
          stuck_count         <= (others => '0');
          invalid_fault       <= '0';
          unstable_fault      <= '0';
          stuck_fault         <= '0';

        elsif active_enable_run = '0' then
          invalid_fault  <= '0';
          unstable_fault <= '0';
          stuck_fault    <= '0';
          stuck_timer_ticks <= (others => '0');

        else
          -- one-cycle fault pulses are latched as status until the next valid accepted sample clears them
          if (real_invalid_pulse = '1') or (sim_invalid_pulse = '1') then
            invalid_count  <= inc_sat_u16(invalid_count);
            invalid_fault  <= '1';
            proc_dist_raw_u16 <= x"FFFF";
          end if;

          if (real_poll_good_pulse = '1') or (sim_good_pulse = '1') then
            if simulation_enable = '1' then
              raw_v  := sim_dist_raw10;
              temp_v := sim_temp_raw10;
            else
              raw_v  := unsigned(dist_raw_u16);
              temp_v := unsigned(temp_raw_u16);
            end if;

            proc_dist_raw_u16 <= std_logic_vector(raw_v);
            proc_temp_raw_u16 <= std_logic_vector(temp_v);

            if raw_v = U16_MAX then
              invalid_count <= inc_sat_u16(invalid_count);
              invalid_fault <= '1';
            else
              jump_v := abs_diff_u16(raw_v, last_valid_raw10);

              if (filter_initialized = '1') and (jump_v > max_jump_raw10_u16) then
                unstable_count <= inc_sat_u16(unstable_count);
                unstable_fault <= '1';
              else
                invalid_fault  <= '0';
                unstable_fault <= '0';

                if filter_initialized = '0' then
                  filtered_dist_raw10 <= raw_v;
                  filter_initialized  <= '1';
                elsif filter_enable = '1' then
                  filtered_dist_raw10 <= iir_step_u16(filtered_dist_raw10, raw_v);
                else
                  filtered_dist_raw10 <= raw_v;
                end if;

                if abs_diff_u16(raw_v, last_sample_raw10) <= to_unsigned(5, 16) then
                  if stuck_timer_ticks < stuck_ticks_target then
                    stuck_timer_ticks <= stuck_timer_ticks + 1;
                  else
                    stuck_fault <= '1';
                    stuck_count <= inc_sat_u16(stuck_count);
                  end if;
                else
                  stuck_timer_ticks <= (others => '0');
                  stuck_fault       <= '0';
                end if;

                last_valid_raw10  <= raw_v;
                last_sample_raw10 <= raw_v;
              end if;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Measurement health (valid + age + stale)
  ----------------------------------------------------------------------------
  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        meas_valid     <= '0';
        meas_age_ticks <= (others => '0');
        meas_stale     <= '0';
      else
        if clear_cnt_pulse = '1' then
          meas_valid     <= '0';
          meas_age_ticks <= (others => '0');
          meas_stale     <= '0';

        elsif poll_good_pulse = '1' then
          meas_valid     <= '1';
          meas_age_ticks <= (others => '0');
          meas_stale     <= '0';

        else
          if meas_valid = '1' then
            if meas_age_ticks /= U32_MAX then
              meas_age_ticks <= meas_age_ticks + 1;
            end if;

            if meas_age_ticks > max_age_ticks then
              meas_stale <= '1';
            end if;
          else
            meas_age_ticks <= (others => '0');
            meas_stale     <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Consecutive failure + comm fault
  ----------------------------------------------------------------------------
  process(CLK)
    variable next_fail : unsigned(7 downto 0);
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        consec_fail <= (others => '0');
        comm_fault  <= '0';
      else
        if clear_cnt_pulse = '1' then
          consec_fail <= (others => '0');
          comm_fault  <= '0';
        elsif active_enable_run = '0' then
          consec_fail <= (others => '0');
          comm_fault  <= '0';
        else
          if poll_good_pulse = '1' then
            consec_fail <= (others => '0');
            comm_fault  <= '0';
          elsif poll_fail_pulse = '1' then
            if consec_fail /= to_unsigned(255, 8) then
              next_fail := consec_fail + 1;
            else
              next_fail := consec_fail;
            end if;

            consec_fail <= next_fail;

            if next_fail >= COMM_FAIL_N then
              comm_fault <= '1';
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Obstacle latch with hysteresis (raw compare in 0.1mm)
  ----------------------------------------------------------------------------
  process(CLK)
    variable d_u16 : u16_t;
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        obstacle_latched <= '0';
      else
        if clear_cnt_pulse = '1' then
          obstacle_latched <= '0';
        elsif meas_valid = '1' and meas_stale = '0' and comm_fault = '0' and proc_dist_raw_u16 /= x"FFFF" then
          d_u16 := filtered_dist_raw10;

          if obstacle_latched = '0' then
            if d_u16 <= threshold_raw10_u16 then
              obstacle_latched <= '1';
            end if;
          else
            if d_u16 >= threshold_clear_raw10_u16 then
              obstacle_latched <= '0';
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Data OK gate
  ----------------------------------------------------------------------------
  process(meas_valid, meas_stale, comm_fault, active_enable_run, active_enable_out, proc_dist_raw_u16, invalid_fault, unstable_fault, stuck_fault)
  begin
    if (active_enable_run = '1') and (active_enable_out = '1') and
       (meas_valid = '1') and (meas_stale = '0') and (comm_fault = '0') and
       (proc_dist_raw_u16 /= x"FFFF") and (invalid_fault = '0') and
       (unstable_fault = '0') and (stuck_fault = '0') then
      data_ok <= '1';
    else
      data_ok <= '0';
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- V07 diagnostic state + error code + quality score
  ----------------------------------------------------------------------------
  process(CLK)
    variable q : integer range -200 to 100;
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        state_b        <= ST_IDLE;
        error_code_b   <= x"00";
        sensor_quality <= to_unsigned(0, 8);
      else
        -- State/error priority. Fault states intentionally override simulation-active state.
        if flag_use_rec101 = '1' and rec_valid = '0' then
          state_b      <= ST_WAIT_REC;
          error_code_b <= x"01";
        elsif active_enable_run = '0' then
          state_b      <= ST_IDLE;
          error_code_b <= x"00";
        elsif comm_fault = '1' then
          state_b      <= ST_COMM_FAULT;
          error_code_b <= x"05";
        elsif (last_timeout = '1') or (sim_timeout_fault = '1') or (comm_error_latched = x"02") then
          state_b      <= ST_TIMEOUT_FAULT;
          error_code_b <= x"02";
        elsif (last_crc_bad = '1') or (comm_error_latched = x"03") then
          state_b      <= ST_CRC_FAULT;
          error_code_b <= x"03";
        elsif invalid_fault = '1' then
          state_b      <= ST_INVALID_VALUE;
          error_code_b <= x"04";
        elsif meas_stale = '1' then
          state_b      <= ST_STALE_DATA;
          error_code_b <= x"07";
        elsif unstable_fault = '1' then
          state_b      <= ST_UNSTABLE_SIGNAL;
          error_code_b <= x"08";
        elsif stuck_fault = '1' then
          state_b      <= ST_STUCK_VALUE;
          error_code_b <= x"09";
        elsif simulation_active = '1' then
          state_b      <= ST_SIMULATION_ACTIVE;
          error_code_b <= x"00";
        elsif data_ok = '1' then
          state_b      <= ST_VALID_DATA;
          error_code_b <= x"00";
        elsif active_enable_out = '0' then
          state_b      <= ST_OUTPUT_DISABLED;
          error_code_b <= x"00";
        else
          state_b      <= ST_REAL_POLLING;
          error_code_b <= comm_error_latched;
        end if;

        -- Deterministic sensor-quality score for HMI/diagnostics. Not AI.
        q := 100;
        if active_enable_run = '0' then
          q := 0;
        else
          if comm_fault = '1' then q := q - 50; end if;
          if (last_timeout = '1') or (sim_timeout_fault = '1') or (comm_error_latched = x"02") then q := q - 40; end if;
          if (last_crc_bad = '1') or (comm_error_latched = x"03") then q := q - 30; end if;
          if invalid_fault = '1' then q := q - 30; end if;
          if meas_stale = '1' then q := q - 25; end if;
          if unstable_fault = '1' then q := q - 20; end if;
          if stuck_fault = '1' then q := q - 15; end if;
        end if;

        if q < 0 then
          sensor_quality <= to_unsigned(0, 8);
        elsif q > 100 then
          sensor_quality <= to_unsigned(100, 8);
        else
          sensor_quality <= to_unsigned(q, 8);
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- DQ outputs (DQ0=FWD, DQ1=REV, DQ3=ENABLE; skip DQ2)
  ----------------------------------------------------------------------------
  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        dq_r <= (others => '0');
        output_state_b <= x"00";
      else
        dq_r <= (others => '0');
        output_state_b <= x"00";

        if data_ok = '1' then
          if DQ_QUANTITY > 3 then
            dq_r(3) <= '1';
          end if;

          case active_mode is
            when x"01" =>
              if obstacle_latched = '0' then
                if DQ_QUANTITY > 0 then dq_r(0) <= '1'; end if;
                output_state_b <= x"01"; -- forward/clear
              else
                output_state_b <= x"03"; -- obstacle latched, hold
              end if;

            when x"02" | x"03" =>
              if obstacle_latched = '0' then
                if DQ_QUANTITY > 0 then dq_r(0) <= '1'; end if;
                output_state_b <= x"01"; -- forward/clear
              else
                if DQ_QUANTITY > 1 then dq_r(1) <= '1'; end if;
                output_state_b <= x"02"; -- reverse/obstacle
              end if;

            when others =>
              null;
          end case;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Publish FB_IF + RD_REC102 (V07 industrial diagnostics contract)
  ----------------------------------------------------------------------------
  process(CLK)
    variable status_dw1 : dword_t;
    variable fb2_dw     : dword_t;
    variable fb3_dw     : dword_t;
    variable rd2_dw2    : dword_t;
    variable rd3_dw3    : dword_t;
    variable rd4_dw4    : dword_t;
    variable rd5_dw5    : dword_t;
    variable rd6_dw6    : dword_t;
  begin
    if rising_edge(CLK) then
      if RST='1' or CPU_STOP='1' then
        fb_if_r  <= (others => (others => '0'));
        rd_rec_r <= (others => (others => '0'));
      else
        -- FB_IF(0): heartbeat
        fb_if_r(0) <= std_logic_vector(heartbeat);

        -- FB_IF(1): parameter sequence + error code + diagnostic state
        status_dw1 := (others => '0');
        status_dw1(31 downto 16) := active_param_seq;
        status_dw1(15 downto 8)  := error_code_b;
        status_dw1(7 downto 0)   := state_b;

        if FB_IF_DWORD_SIZE > 1 then
          fb_if_r(1) <= status_dw1;
        end if;

        -- FB_IF(2): filtered distance + raw distance, both in 0.1 mm units
        fb2_dw := (others => '0');
        fb2_dw(31 downto 16) := std_logic_vector(filtered_dist_raw10);
        fb2_dw(15 downto 0)  := proc_dist_raw_u16;
        if FB_IF_DWORD_SIZE > 2 then
          fb_if_r(2) <= fb2_dw;
        end if;

        -- FB_IF(3): output state + quality + raw temperature in 0.1 C units
        fb3_dw := (others => '0');
        fb3_dw(31 downto 24) := output_state_b;
        fb3_dw(23 downto 16) := std_logic_vector(sensor_quality);
        fb3_dw(15 downto 0)  := proc_temp_raw_u16;
        if FB_IF_DWORD_SIZE > 3 then
          fb_if_r(3) <= fb3_dw;
        end if;

        -- RD_REC102 diagnostic snapshot
        rd_rec_r(0) <= MAGIC_V07;
        rd_rec_r(1) <= status_dw1;

        rd2_dw2 := (others => '0');
        rd2_dw2(31) := comm_fault;
        rd2_dw2(30) := data_ok;
        rd2_dw2(29) := obstacle_latched;
        rd2_dw2(28) := meas_stale;
        rd2_dw2(27) := simulation_active;
        rd2_dw2(26) := unstable_fault;
        rd2_dw2(25) := stuck_fault;
        rd2_dw2(24) := last_rx_ok;
        rd2_dw2(23) := last_crc_bad;
        rd2_dw2(22) := last_timeout or sim_timeout_fault;
        rd2_dw2(21 downto 16) := std_logic_vector(last_rx_len);
        rd2_dw2(15 downto 0)  := proc_dist_raw_u16;
        rd_rec_r(2) <= rd2_dw2;

        rd3_dw3 := (others => '0');
        rd3_dw3(31 downto 16) := std_logic_vector(filtered_dist_raw10);
        rd3_dw3(15 downto 0)  := proc_temp_raw_u16;
        rd_rec_r(3) <= rd3_dw3;

        rd4_dw4 := (others => '0');
        rd4_dw4(31 downto 16) := std_logic_vector(rx_ok_count);
        rd4_dw4(15 downto 0)  := std_logic_vector(tx_count);
        rd_rec_r(4) <= rd4_dw4;

        rd5_dw5 := (others => '0');
        rd5_dw5(31 downto 16) := std_logic_vector(rx_crc_bad_count);
        rd5_dw5(15 downto 0)  := std_logic_vector(rx_timeout_count);
        rd_rec_r(5) <= rd5_dw5;

        rd6_dw6 := (others => '0');
        rd6_dw6(31 downto 16) := std_logic_vector(unstable_count);
        rd6_dw6(15 downto 0)  := std_logic_vector(invalid_count);
        rd_rec_r(6) <= rd6_dw6;

        rd_rec_r(7)(31 downto 16) <= std_logic_vector(stuck_count);
        rd_rec_r(7)(15 downto 0)  <= std_logic_vector(commit_cnt);
      end if;
    end if;
  end process;

end architecture TM_FAST_V07_URM14_Diagnostics;
