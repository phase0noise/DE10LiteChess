library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;
use std.env.all;

entity tb_chess_uart is end;
architecture test of tb_chess_uart is
  signal clk : std_logic := '0';
  signal reset,rx_valid,rx_error,tx_start : std_logic := '0';
  signal tx_ready : std_logic := '1';
  signal rx_data,tx_data : byte_t := x"00";
  signal panel : std_logic_vector(31 downto 0);
  signal activity : std_logic_vector(17 downto 0);
  signal received : bytes_t(0 to 1100);
  signal count : natural range 0 to 1100 := 0;
  signal clear : std_logic := '0';
  function crc_byte(c : unsigned(15 downto 0); b : byte_t) return unsigned is
    variable v : unsigned(15 downto 0) := c xor shift_left(resize(unsigned(b),16),8);
  begin
    for i in 0 to 7 loop
      if v(15)='1' then v:=shift_left(v,1) xor x"1021";else v:=shift_left(v,1);end if;
    end loop;return v;
  end;
begin
  clk<=not clk after 10 ns;
  dut : entity work.chess_uart_bridge generic map(CLOCK_HZ=>100000,CHESS_DIVIDE=>4)
    port map(clk=>clk,reset=>reset,rx_valid=>rx_valid,rx_error=>rx_error,rx_data=>rx_data,
      tx_ready=>tx_ready,tx_start=>tx_start,tx_data=>tx_data,keys=>(others=>'0'),panel=>panel,activity=>activity);
  process(clk)
    variable hold : natural range 0 to 3 := 0;
  begin
    if rising_edge(clk) then
      if clear='1' then count<=0;end if;
      if tx_start='1' and tx_ready='1' then
        received(count)<=tx_data;count<=count+1;tx_ready<='0';hold:=3;
      elsif hold>0 then hold:=hold-1;
      else tx_ready<='1';end if;
    end if;
  end process;
  process
    variable packet : bytes_t(0 to 80) := (others=>x"00");
    variable token : natural := 1;
    variable gen,best,legal,n : natural;
    variable crc : unsigned(15 downto 0);
    type seen_t is array(0 to 4095) of boolean;
    variable expected : seen_t := (others=>false);
    variable initial : board_t := initial_board;
    procedure byte_in(constant b : byte_t) is
    begin
      wait until falling_edge(clk);rx_data<=b;rx_valid<='1';
      wait until falling_edge(clk);rx_valid<='0';
      wait until falling_edge(clk);
    end;
    procedure send(constant length : natural; constant bad_crc : boolean := false) is
      variable c : unsigned(15 downto 0) := x"FFFF";
      variable b : byte_t;
    begin
      clear<='1';wait until falling_edge(clk);clear<='0';
      byte_in(x"43");byte_in(x"46");byte_in(x"01");c:=crc_byte(c,x"01");
      for i in 3 downto 0 loop b:=oct(token/(256**i));byte_in(b);c:=crc_byte(c,b);end loop;
      b:=oct(length);byte_in(b);c:=crc_byte(c,b);
      for i in 0 to length-1 loop byte_in(packet(i));c:=crc_byte(c,packet(i));end loop;
      if bad_crc then c:=c xor x"0001";end if;
      byte_in(std_logic_vector(c(15 downto 8)));byte_in(std_logic_vector(c(7 downto 0)));
    end;
    procedure response(constant length : natural;constant status : natural := 0) is
      variable c : unsigned(15 downto 0) := x"FFFF";
    begin
      for cycle in 0 to 50000 loop wait until falling_edge(clk);exit when count=length+12;end loop;
      assert count=length+12 report "UART response timed out" severity failure;
      assert received(0)=x"46" and received(1)=x"43" and received(2)=x"01" report "bad reply magic" severity failure;
      for i in 0 to 3 loop assert received(3+i)=oct(token/(256**(3-i))) report "wrong sequence" severity failure;end loop;
      assert received(7)=oct(status) report "wrong response status for command "&integer'image(to_integer(unsigned(packet(0))))&
        ": actual "&integer'image(to_integer(unsigned(received(7))))&" expected "&integer'image(status) severity failure;
      assert received(8)=oct(length/256) and received(9)=oct(length) report "wrong length" severity failure;
      for i in 2 to length+9 loop c:=crc_byte(c,received(i));end loop;
      assert received(length+10)=std_logic_vector(c(15 downto 8)) and received(length+11)=std_logic_vector(c(7 downto 0)) report "reply CRC mismatch" severity failure;
      wait for 1 us;
    end;
    procedure status_read is
    begin packet(0):=x"00";token:=token+1;send(1);response(32);end;
  begin
    reset<='1';wait for 200 ns;wait until falling_edge(clk);reset<='0';wait for 20 us;
    status_read;
    assert received(10)=x"53" and received(11)=x"43" and received(12)=x"46" and received(13)=x"31" report "status pipeline corrupted" severity failure;
    assert received(25)=x"04" report "wrong chess protocol" severity failure;

    -- Lost reply / retry cannot reset the factual position twice.
    packet(0):=x"0A";token:=token+1;send(1);response(1);
    send(1);response(1);
    status_read;assert received(33)=x"01" report "duplicate mutation replayed" severity failure;
    packet(0):=x"0A";token:=token+1;send(1,true);wait for 5 us;
    assert count=0 report "corrupt request executed" severity failure;
    status_read;assert received(33)=x"01" report "bad CRC changed position" severity failure;

    -- Incomplete frames, bad versions, oversized lengths and framing errors
    -- recover cleanly before the next complete command.
    byte_in(x"43");byte_in(x"46");byte_in(x"01");wait for 120 us;status_read;
    byte_in(x"43");byte_in(x"46");byte_in(x"02");status_read;
    byte_in(x"43");byte_in(x"46");byte_in(x"01");
    for i in 0 to 3 loop byte_in(x"00");end loop;byte_in(x"52");status_read;
    byte_in(x"43");rx_error<='1';wait until falling_edge(clk);rx_error<='0';status_read;

    -- Max-size configuration packet and RAM-backed readback exercise every
    -- byte and both UART CRC directions, including non-repeated values.
    packet(0):=x"08";
    for i in 1 to 80 loop packet(i):=oct(i);end loop;
    packet(1):=x"00";packet(5):=x"00";
    token:=token+1;send(81);response(1);
    packet(0):=x"06";token:=token+1;send(1);response(80);
    for i in 0 to 79 loop
      if i=0 or i=4 then n:=0;else n:=i+1;end if;
      assert received(10+i)=oct(n) report "configuration RAM read pipeline byte "&integer'image(i) severity failure;
    end loop;
    packet(0):=x"0D";packet(1):=x"00";
    for i in 0 to 63 loop packet(i+2):=policy_defaults(i);end loop;
    -- Validate deeper-search limits through the real framed UART bridge.
    for bad in 0 to 4 loop
      packet(12):=x"05";packet(42):=x"0A";packet(43):=x"04";packet(44):=x"01";
      case bad is
        when 0=>packet(12):=x"01";
        when 1=>packet(12):=x"07";
        when 2=>packet(42):=x"3D";
        when 3=>packet(43):=x"05";
        when others=>packet(44):=x"02";
      end case;
      token:=token+1;send(66);response(1,3);
    end loop;
    packet(12):=x"06";packet(42):=x"0A";packet(43):=x"04";packet(44):=x"01";
    token:=token+1;send(66);response(1);
    packet(0):=x"0C";token:=token+1;send(2);response(64);
    assert received(20)=x"06" and received(50)=x"0A" and received(51)=x"04" and received(52)=x"01"
      report "expanded policy upload/readback mismatch" severity failure;
    packet(0):=x"0D";
    packet(12):=x"00";token:=token+1;send(66);response(1);
    packet(0):=x"02";token:=token+1;send(1);response(1);
    for poll in 0 to 500 loop
      status_read;exit when received(14)=x"00" and received(15)=x"01";wait for 20 us;
    end loop;
    assert received(15)=x"01" report "UART-driven evaluation did not finish" severity failure;
    legal:=to_integer(unsigned(received(18)))*256+to_integer(unsigned(received(19)));
    best:=to_integer(unsigned(received(20)))*256+to_integer(unsigned(received(21)));
    gen:=to_integer(unsigned(received(33)));
    assert legal=20 report "wrong starting legal set" severity failure;
    packet(0):=x"12";token:=token+1;send(1);response(20);
    assert received(18)=x"00" and received(19)=x"04" and received(20)=x"00" and received(21)=x"02"
      report "expanded search telemetry framing mismatch" severity failure;
    expected(1+16*64):=true;expected(1+18*64):=true;
    expected(6+21*64):=true;expected(6+23*64):=true;
    for s in 8 to 15 loop expected(s+(s+8)*64):=true;expected(s+(s+16)*64):=true;end loop;
    assert expected(best) report "selected opening move was illegal" severity failure;
    for page in 0 to 1 loop
      packet(0):=x"07";packet(1):=oct(page);token:=token+1;send(2);response(64);
      for i in 0 to 15 loop
        if page*16+i<20 then
          n:=to_integer(unsigned(received(10+4*i)))*256+to_integer(unsigned(received(11+4*i)));
          assert n<4096 and expected(n) report "candidate RAM pipeline returned an illegal or duplicate move" severity failure;
          expected(n):=false;
        end if;
      end loop;
    end loop;
    packet(0):=x"0B";packet(1):=x"00";packet(2):=x"00";packet(3):=x"00";packet(4):=oct(gen);
    packet(5):=oct(best/256);packet(6):=oct(best);token:=token+1;send(7);response(1);
    packet(0):=x"05";token:=token+1;send(1);response(67);
    initial(best/64 mod 64):=initial(best mod 64);initial(best mod 64):=x"0";
    for s in 0 to 63 loop assert received(10+s)=x"0"&initial(s) report "committed board readback mismatch" severity failure;end loop;
    assert received(74)=x"01" report "committed move did not change side" severity failure;
    assert received(75)=x"0F" report "opening move corrupted castling rights" severity failure;
    packet(0):=x"0B";packet(4):=oct(gen);packet(5):=oct(best/256);packet(6):=oct(best);
    token:=token+1;send(7);response(1,3);
    report "UART framing, CRC, retries, malformed-frame recovery, RAM readback, evaluation and guarded commit passed" severity note;
    finish;
  end process;
end;
