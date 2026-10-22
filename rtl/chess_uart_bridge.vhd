-- Framed, CRC-protected byte transport for the unchanged chess command API.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_uart_bridge is
  generic(CLOCK_HZ : positive := 50000000; CHESS_DIVIDE : positive := 4);
  port(clk, reset : in std_logic;
    rx_valid, rx_error : in std_logic; rx_data : in byte_t;
    tx_ready : in std_logic; tx_start : out std_logic; tx_data : out byte_t;
    keys : in std_logic_vector(3 downto 0);
    panel : out std_logic_vector(31 downto 0);
    activity : out std_logic_vector(17 downto 0));
end;

architecture rtl of chess_uart_bridge is
  type state_t is (MAGIC_C, MAGIC_F, VERSION, SEQUENCE_BYTES, LENGTH_BYTE,
    PAYLOAD, CRC_HI, CRC_LO, COPY_REQUEST, ISSUE, EXECUTE,
    SNAP_ADDRESS, SNAP_WAIT1, SNAP_WAIT2, SNAP_STORE,
    SEND_SELECT, SEND_START, SEND_ACK, SEND_WAIT, SEND_READ);
  signal state : state_t := MAGIC_C;
  signal request : bytes_t(0 to 80);
  signal reply : bytes_t(0 to 1023);
  attribute ramstyle : string;
  attribute ramstyle of reply : signal is "M9K, no_rw_check";
  signal reply_q : byte_t;
  signal reply_address : natural range 0 to 1023 := 0;
  signal seq : std_logic_vector(31 downto 0) := (others=>'0');
  signal seq_index : natural range 0 to 3 := 0;
  signal length_i : natural range 0 to 81 := 1;
  signal index_i : natural range 0 to 1035 := 0;
  signal copy_index : natural range 0 to 1023 := 0;
  signal crc, wire_crc, send_crc : unsigned(15 downto 0) := (others=>'1');
  signal watchdog : natural range 0 to CLOCK_HZ/10 := 0;
  signal engine_we, engine_command, engine_done : std_logic := '0';
  signal engine_rx_address : natural range 0 to 80 := 0;
  signal engine_rx_data, engine_read_data : byte_t := x"00";
  signal engine_read_address : natural range 0 to 1023 := 0;
  signal engine_status : natural range 0 to 3;
  signal engine_length : natural range 0 to 1024;
  signal reply_status : natural range 0 to 4 := 0;
  signal reply_length : natural range 0 to 1024 := 0;
  function crc_byte(c : unsigned(15 downto 0); b : byte_t) return unsigned is
    variable v : unsigned(15 downto 0) := c xor shift_left(resize(unsigned(b),16),8);
  begin
    for n in 0 to 7 loop
      if v(15)='1' then v:=shift_left(v,1) xor x"1021"; else v:=shift_left(v,1); end if;
    end loop;
    return v;
  end;
begin
  engine : entity work.chess_engine generic map(CLOCK_DIVIDE=>CHESS_DIVIDE)
    port map(clk=>clk, reset=>reset, rx_we=>engine_we,
      rx_address=>engine_rx_address, rx_data=>engine_rx_data,
      command=>engine_command, request_length=>length_i,
      request_token=>x"5049434F5731" & seq,
      response_done=>engine_done, response_status=>engine_status,
      response_length=>engine_length, read_address=>engine_read_address,
      read_data=>engine_read_data, switches=>(others=>'0'), keys=>keys,
      panel=>panel, activity=>activity);

  -- Capture a complete reply before UART transmission. Live engine state may
  -- continue to evolve while the serial link spends milliseconds sending it.
  process(clk) begin
    if rising_edge(clk) then
      reply_q<=reply(reply_address);
      if state=SNAP_STORE then reply(copy_index)<=engine_read_data; end if;
    end if;
  end process;

  process(clk)
    variable b : byte_t;
  begin
    if rising_edge(clk) then
      engine_we<='0'; tx_start<='0';
      if reset='1' then
        state<=MAGIC_C; watchdog<=0; engine_command<='0'; tx_data<=x"00";
        seq<=(others=>'0'); crc<=(others=>'1');
      else
        case state is
          when MAGIC_C =>
            watchdog<=0;
            if rx_valid='1' and rx_data=x"43" then state<=MAGIC_F; end if;
          when MAGIC_F =>
            if rx_valid='1' then
              if rx_data=x"46" then state<=VERSION;
              elsif rx_data/=x"43" then state<=MAGIC_C; end if;
            end if;
          when VERSION =>
            if rx_valid='1' then
              if rx_data=x"01" then crc<=crc_byte(x"FFFF",rx_data); seq_index<=0; state<=SEQUENCE_BYTES;
              else state<=MAGIC_C; end if;
            end if;
          when SEQUENCE_BYTES =>
            if rx_valid='1' then
              seq<=seq(23 downto 0)&rx_data; crc<=crc_byte(crc,rx_data);
              if seq_index=3 then state<=LENGTH_BYTE; else seq_index<=seq_index+1; end if;
            end if;
          when LENGTH_BYTE =>
            if rx_valid='1' then
              if unsigned(rx_data)>=1 and unsigned(rx_data)<=81 then
                length_i<=to_integer(unsigned(rx_data)); index_i<=0;
                crc<=crc_byte(crc,rx_data); state<=PAYLOAD;
              else state<=MAGIC_C; end if;
            end if;
          when PAYLOAD =>
            if rx_valid='1' then
              request(index_i)<=rx_data; crc<=crc_byte(crc,rx_data);
              if index_i=length_i-1 then state<=CRC_HI; else index_i<=index_i+1; end if;
            end if;
          when CRC_HI =>
            if rx_valid='1' then wire_crc(15 downto 8)<=unsigned(rx_data); state<=CRC_LO; end if;
          when CRC_LO =>
            if rx_valid='1' then
              if wire_crc(15 downto 8)&unsigned(rx_data)=crc then index_i<=0; state<=COPY_REQUEST;
              else state<=MAGIC_C; end if;
            end if;
          when COPY_REQUEST =>
            engine_we<='1'; engine_rx_address<=index_i; engine_rx_data<=request(index_i);
            if index_i=length_i-1 then state<=ISSUE; else index_i<=index_i+1; end if;
          when ISSUE => engine_command<='1'; watchdog<=0; state<=EXECUTE;
          when EXECUTE =>
            if engine_done='1' then
              engine_command<='0'; reply_status<=engine_status; reply_length<=engine_length;
              copy_index<=0;
              if engine_length=0 then index_i<=0; send_crc<=(others=>'1'); state<=SEND_SELECT;
              else state<=SNAP_ADDRESS; end if;
            elsif watchdog=CLOCK_HZ/10 then
              engine_command<='0'; reply_status<=4; reply_length<=0;
              index_i<=0; send_crc<=(others=>'1'); state<=SEND_SELECT;
            else watchdog<=watchdog+1; end if;
          when SNAP_ADDRESS => engine_read_address<=copy_index; state<=SNAP_WAIT1;
          when SNAP_WAIT1 => state<=SNAP_WAIT2;
          when SNAP_WAIT2 => state<=SNAP_STORE;
          when SNAP_STORE =>
            if copy_index=reply_length-1 then
              index_i<=0; send_crc<=(others=>'1'); state<=SEND_SELECT;
            else copy_index<=copy_index+1; state<=SNAP_ADDRESS; end if;
          when SEND_SELECT =>
            case index_i is
              when 0 => b:=x"46";
              when 1 => b:=x"43";
              when 2 => b:=x"01";
              when 3 => b:=seq(31 downto 24);
              when 4 => b:=seq(23 downto 16);
              when 5 => b:=seq(15 downto 8);
              when 6 => b:=seq(7 downto 0);
              when 7 => b:=oct(reply_status);
              when 8 => b:=oct(reply_length/256);
              when 9 => b:=oct(reply_length);
              when others =>
                if index_i=reply_length+10 then b:=std_logic_vector(send_crc(15 downto 8));
                elsif index_i=reply_length+11 then b:=std_logic_vector(send_crc(7 downto 0));
                else b:=reply_q; end if;
            end case;
            if index_i>=2 and index_i<reply_length+10 then send_crc<=crc_byte(send_crc,b); end if;
            tx_data<=b; state<=SEND_START;
          when SEND_START =>
            if tx_ready='1' then tx_start<='1'; state<=SEND_ACK; end if;
          when SEND_ACK => if tx_ready='0' then state<=SEND_WAIT; end if;
          when SEND_WAIT =>
            if tx_ready='1' then
              if index_i=reply_length+11 then state<=MAGIC_C;
              else
                index_i<=index_i+1;
                if index_i>=9 and index_i<reply_length+9 then reply_address<=index_i-9; end if;
                state<=SEND_READ;
              end if;
            end if;
          when SEND_READ => state<=SEND_SELECT;
        end case;
        -- Abandon partial frames after 50 ms. Never issue unverified bytes.
        if state=MAGIC_F or state=VERSION or state=SEQUENCE_BYTES or state=LENGTH_BYTE or
           state=PAYLOAD or state=CRC_HI or state=CRC_LO then
          if rx_error='1' then state<=MAGIC_C; watchdog<=0;
          elsif rx_valid='1' then watchdog<=0;
          elsif watchdog>=CLOCK_HZ/20 then state<=MAGIC_C; watchdog<=0;
          else watchdog<=watchdog+1; end if;
        end if;
      end if;
    end if;
  end process;
end;
