library ieee;
use ieee.std_logic_1164.all;

entity de10_chess is
  port(MAX10_CLK1_50 : in std_logic;
    KEY : in std_logic_vector(1 downto 0);
    UART_RX_PIN : in std_logic; UART_TX_PIN : out std_logic;
    LEDR : out std_logic_vector(9 downto 0);
    HEX0,HEX1,HEX2,HEX3,HEX4,HEX5 : out std_logic_vector(7 downto 0));
end;

architecture rtl of de10_chess is
  component uart_rx is
    generic(CLOCK_FREQ : integer := 50000000; BAUD_RATE : integer := 9600; HIGH_BAUD_RATE : integer := 115200);
    port(clk,reset,high_speed,rx : in std_logic;
      rx_data : out std_logic_vector(7 downto 0); rx_valid,rx_frame_error : out std_logic);
  end component;
  component uart_tx is
    generic(CLOCK_FREQ : integer := 50000000; BAUD_RATE : integer := 9600; HIGH_BAUD_RATE : integer := 115200);
    port(clk,reset,high_speed,tx_start : in std_logic; tx_data : in std_logic_vector(7 downto 0);
      tx,tx_ready : out std_logic);
  end component;
  signal reset_pipe : std_logic_vector(3 downto 0) := (others=>'1');
  signal reset : std_logic;
  signal key_meta,key_sync : std_logic := '1';
  signal rx_byte,tx_byte : std_logic_vector(7 downto 0);
  signal rx_valid,rx_error,tx_start,tx_ready : std_logic;
  signal panel : std_logic_vector(31 downto 0);
  signal activity : std_logic_vector(17 downto 0);
  function digit(n : std_logic_vector(3 downto 0)) return std_logic_vector is
  begin
    case n is
      when x"0"=>return x"C0"; when x"1"=>return x"F9";
      when x"2"=>return x"A4"; when x"3"=>return x"B0";
      when x"4"=>return x"99"; when x"5"=>return x"92";
      when x"6"=>return x"82"; when x"7"=>return x"F8";
      when x"8"=>return x"80"; when x"9"=>return x"90";
      when x"A"=>return x"88"; when x"B"=>return x"83";
      when x"C"=>return x"C6"; when x"D"=>return x"A1";
      when x"E"=>return x"86"; when others=>return x"8E";
    end case;
  end;
begin
  process(MAX10_CLK1_50, KEY(0)) begin
    if KEY(0)='0' then reset_pipe<=(others=>'1');
    elsif rising_edge(MAX10_CLK1_50) then reset_pipe<=reset_pipe(2 downto 0)&'0'; end if;
  end process;
  reset<=reset_pipe(3);
  process(MAX10_CLK1_50) begin
    if rising_edge(MAX10_CLK1_50) then key_meta<=KEY(1); key_sync<=key_meta; end if;
  end process;
  receiver : uart_rx port map(clk=>MAX10_CLK1_50,reset=>reset,high_speed=>'1',rx=>UART_RX_PIN,
    rx_data=>rx_byte,rx_valid=>rx_valid,rx_frame_error=>rx_error);
  transmitter : uart_tx port map(clk=>MAX10_CLK1_50,reset=>reset,high_speed=>'1',tx_start=>tx_start,
    tx_data=>tx_byte,tx=>UART_TX_PIN,tx_ready=>tx_ready);
  link : entity work.chess_uart_bridge port map(clk=>MAX10_CLK1_50,reset=>reset,
    rx_valid=>rx_valid,rx_error=>rx_error,rx_data=>rx_byte,
    tx_ready=>tx_ready,tx_start=>tx_start,tx_data=>tx_byte,
    keys=>(1=>not key_sync,others=>'0'),panel=>panel,activity=>activity);
  LEDR(7 downto 0)<=activity(7 downto 0);
  LEDR(8)<=activity(16); -- Side to move: 0 white, 1 black.
  LEDR(9)<=activity(17); -- Evaluator busy.
  HEX0<=digit(panel(19 downto 16)); HEX1<=digit(panel(23 downto 20));
  HEX2<=digit(panel(27 downto 24)); HEX3<=digit(panel(31 downto 28));
  HEX4<=digit(panel(11 downto 8)); HEX5<=digit(panel(3 downto 0));
end;
