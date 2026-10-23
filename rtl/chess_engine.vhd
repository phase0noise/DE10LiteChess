-- Shared speculative board, spatial legality filter, and 64 recurrent cells.
-- Host commands are bounded; the evaluator runs independently of UART traffic.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_engine is
  generic(CLOCK_DIVIDE : positive := 4; TRACE_SEARCH : boolean := false; CLOCK_HZ : positive := 50000000);
  port(clk,reset : in std_logic;
    rx_we : in std_logic; rx_address : in natural range 0 to 80; rx_data : in byte_t;
    command : in std_logic; request_length : in natural range 0 to 81;
    request_token : in std_logic_vector(79 downto 0);
    response_done : out std_logic; response_status : out natural range 0 to 3;
    response_length : out natural range 0 to 1024;
    read_address : in natural range 0 to 1023; read_data : out byte_t;
    switches : in std_logic_vector(17 downto 0); keys : in std_logic_vector(3 downto 0);
    panel : out std_logic_vector(31 downto 0);
    activity : out std_logic_vector(17 downto 0) := (others=>'0'));
end;

architecture fabric of chess_engine is
  type state_t is (IDLE, SNAPSHOT, RELAX, PICK, APPLY, SETTLE, INSPECT, SCORE_MOVE, RESTORE, ADVANCE, FINISH, COMMIT_MOVE, LOAD_SCAN, LOAD_FINISH, AUDIT_RESET, AUDIT_CELL, AUDIT_DONE, LOAD_POLICY, BOOT_POLICY, SEARCH_SAVE, SEARCH_BEGIN, SEARCH_RECALL_WAIT, SEARCH_RECALL_COPY, SEARCH_ACCEPT, SEARCH_RETURN, SEARCH_ROOT, LOAD_ROUTES, SEARCH_SUM, SEARCH_ADD, SEARCH_SCORE,
    CACHE_CLEAR, EVAL_PAWNS, EVAL_BLEND, EVAL_DONE, CACHE_PROBE, NODE_READY, MOVE_SELECT, MOVE_APPLY);
  signal state : state_t := IDLE;
  signal phase : natural range 0 to CLOCK_DIVIDE-1 := 0;
  signal command_seen : std_logic := '0';
  signal base,b : board_t := initial_board;
  signal rx : bytes_t(0 to 80) := (others=>x"00");
  signal packet_rx : bytes_t(0 to 80);
  signal packet_length : natural range 0 to 81 := 0;
  signal packet_token : std_logic_vector(79 downto 0) := (others=>'0');
  signal command_pending : std_logic := '0';
  signal cfg : bytes_t(0 to 15) := (
    0=>x"20",1=>x"18",2=>x"20",3=>x"08",4=>x"20",5=>x"10",6=>x"08",7=>x"08",
    8=>x"08",9=>x"04",10=>x"04",11=>x"00",12=>x"00",13=>x"00",14=>x"00",15=>x"00",others=>x"FF");
  signal route_table : bytes_t(0 to 63);
  signal snapshot_table : bytes_t(0 to 63);
  signal route_q,route_host_q,snapshot_q : byte_t;
  signal route_index : natural range 0 to 63 := 0;
  signal route_address : natural range 0 to 63;
  signal field_leds : std_logic_vector(15 downto 0) := (others=>'0');
  signal field_valid : std_logic_vector(63 downto 0) := (others=>'0');
  constant INIT_POLICY : bytes_t(0 to 127) := policy_defaults;
  signal policy : bytes_t(0 to 42) := INIT_POLICY(0 to 42);
  attribute ramstyle : string;
  attribute ramstyle of route_table,snapshot_table : signal is "M9K, no_rw_check";
  signal policy_initialized : std_logic := '0';
  signal policy_boot_index : natural range 0 to 127 := 0;
  signal mem_policy_we,mem_cell_we : std_logic;
  signal mem_policy_data,mem_cell_data : byte_t;
  signal mem_policy_b_address : natural range 0 to 127 := 64;
  signal mem_policy_a,mem_policy_b,mem_field_a,mem_field_b : byte_t;
  signal cell_address_a : natural range 0 to 63 := 0;
  signal table_address_a : natural range 0 to 127 := 0;
  signal policy_index : natural range 0 to 63 := 0;
  signal neuron_result,neuron_output : integer range -127 to 127 := 0;
  signal neuron_old,neuron_bias : signed(7 downto 0) := (others=>'0');
  signal policy_page : natural range 0 to 1 := 0;
  type history_t is array(0 to 7) of std_logic_vector(15 downto 0);
  signal history : history_t := (others=>(others=>'0'));
  signal history_count : natural range 0 to 8 := 0;
  signal nonpawn_count,load_nonpawn : natural range 0 to 64 := 14;
  signal audit_trial : std_logic := '0';
  signal audit_index : natural range 0 to 63 := 0;
  signal audit_own_max,audit_enemy_max : integer range 0 to 2000 := 0;
  signal audit_own_sum,audit_enemy_sum : integer range 0 to 64000 := 0;
  signal audit_position,base_position : integer range -131072 to 131071 := 0;
  signal base_own_risk,base_enemy_risk : integer range 0 to 18000 := 0;
  signal base_minor_home,audit_minor_home : natural range 0 to 16 := 0;
  signal score_safety,score_progress,score_habit : integer range -131072 to 131071 := 0;
  signal neuron_direction : natural range 0 to 9 := 0;
  signal neighbor_accum : signed(13 downto 0) := (others=>'0');
  -- Shared spatial fabric, serialized board stack: no replicated chess engines.
  type stack_ram_t is array(0 to SEARCH_LEVELS*64-1) of piece_t;
  signal search_stack : stack_ram_t;
  attribute ramstyle of search_stack : signal is "M9K";
  signal search_q : piece_t;
  signal search_sp : natural range 0 to SEARCH_LEVELS-1 := 0;
  signal search_index : natural range 0 to 63 := 0;
  signal search_active,search_returning : std_logic := '0';
  type search_scores_t is array(0 to SEARCH_LEVELS-1) of integer range -30000 to 30000;
  type search_squares_t is array(0 to SEARCH_LEVELS-1) of natural range 0 to 63;
  type search_eps_t is array(0 to SEARCH_LEVELS-1) of natural range 0 to 64;
  type search_promotions_t is array(0 to SEARCH_LEVELS-1) of natural range 2 to 5;
  type search_rights_t is array(0 to SEARCH_LEVELS-1) of std_logic_vector(3 downto 0);
  signal node_static,node_best,node_alpha,node_beta : search_scores_t := (others=>0);
  signal node_wk,node_bk,cursor_src,cursor_dst : search_squares_t := (others=>0);
  signal node_ep : search_eps_t := (others=>64);
  signal cursor_promotion : search_promotions_t := (others=>2);
  signal node_rights : search_rights_t := (others=>"0000");
  signal node_turn,node_check,node_legal,cursor_promoting : std_logic_vector(0 to SEARCH_LEVELS-1) := (others=>'0');
  type node_moves_t is array(0 to SEARCH_LEVELS-1) of std_logic_vector(15 downto 0);
  type node_counts_t is array(0 to SEARCH_LEVELS-1) of natural range 0 to SEARCH_MOVES;
  type node_hashes_t is array(0 to SEARCH_LEVELS-1) of hash_t;
  signal node_count,node_remaining : node_counts_t := (others=>0);
  signal node_hash : node_hashes_t := (others=>(others=>'0'));
  signal node_start_alpha,node_start_beta : search_scores_t;
  signal node_best_move,node_hint,node_killer1,node_killer2 : node_moves_t := (others=>(others=>'0'));
  signal node_hint_valid,node_tactical,node_cached,node_repetition : std_logic_vector(0 to SEARCH_LEVELS-1) := (others=>'0');
  signal node_draw : std_logic_vector(0 to SEARCH_LEVELS-1) := (others=>'0');
  signal node_cache_word : std_logic_vector(127 downto 0);
  signal search_building : std_logic := '0';
  signal search_iteration,search_completed : natural range 0 to MAX_SEARCH_DEPTH := 0;
  signal search_timed_out,search_has_completed,search_running : std_logic := '0';
  signal search_limit : unsigned(31 downto 0) := (others=>'0');
  signal search_epoch : unsigned(15 downto 0) := (others=>'0');
  signal search_cache_hits,search_cache_stores : unsigned(31 downto 0) := (others=>'0');
  signal search_hash_acc : hash_t := (others=>'0');
  signal search_scan,search_pick_index : natural range 0 to SEARCH_MOVES-1 := 0;
  signal search_pick_data : std_logic_vector(31 downto 0) := (others=>'0');
  signal search_clear_index : natural range 0 to CACHE_ENTRIES-1 := 0;
  signal queue_we,cache_we,history_we : std_logic := '0';
  signal queue_write_address,queue_read_address : natural range 0 to SEARCH_LEVELS*SEARCH_MOVES-1 := 0;
  signal queue_write_data,queue_data : std_logic_vector(31 downto 0);
  signal cache_write_address,cache_read_address : natural range 0 to CACHE_ENTRIES-1 := 0;
  signal cache_write_data,cache_data : std_logic_vector(127 downto 0);
  signal history_write_address,history_read_address : natural range 0 to 4095 := 0;
  signal history_write_data,history_data : unsigned(12 downto 0);
  signal hash_data : hash_t;
  signal hash_piece : piece_t;
  type files_t is array(0 to 7) of natural range 0 to 16;
  type ranks_t is array(0 to 7) of natural range 0 to 7;
  signal eval_white_pawns,eval_black_pawns,eval_white_rooks,eval_black_rooks : files_t := (others=>0);
  signal eval_white_min,eval_black_min : ranks_t := (others=>7);
  signal eval_white_max,eval_black_max : ranks_t := (others=>0);
  signal eval_white_bishops,eval_black_bishops : natural range 0 to 16 := 0;
  signal eval_minors,eval_knights : natural range 0 to 32 := 0;
  signal eval_heavy : std_logic := '0';
  signal eval_bishop_colors : std_logic_vector(1 downto 0) := "00";
  signal eval_mg,eval_eg : integer range -131072 to 131071 := 0;
  signal eval_blend_mg,eval_blend_eg : integer range -4194304 to 4194303 := 0;
  signal eval_phase : natural range 0 to 128 := 0;
  signal eval_file : natural range 0 to 7 := 0;
  signal active_turn : std_logic;
  signal active_rights : std_logic_vector(3 downto 0);
  signal active_ep : natural range 0 to 64;
  signal active_wk,active_bk : natural range 0 to 63;
  signal search_result,trial_static,base_static,audit_static : integer range -32768 to 32767 := 0;
  signal search_root_move : std_logic_vector(15 downto 0);
  signal search_parts : std_logic_vector(95 downto 0);
  signal search_delta_score : integer range -32768 to 32767 := 0;
  signal search_sum_a,search_sum_b,search_sum_c : integer range -131072 to 131071 := 0;
  signal search_nodes,search_cutoffs : unsigned(31 downto 0) := (others=>'0');
  -- One shared random stream replaces 64 register/mux banks to make room
  -- for real lookahead. Each serialized cell samples at a different clock.

  signal rng : unsigned(31 downto 0) := x"D0E2C35F";
  signal white_a,black_a,reach : std_logic_vector(63 downto 0);
  signal white_map,black_map : std_logic_vector(63 downto 0) := (others=>'0');
  signal friend_a,enemy_a : std_logic_vector(63 downto 0);
  signal turn : std_logic := '0';
  signal rights : std_logic_vector(3 downto 0) := "1111";
  signal ep : natural range 0 to 64 := 64;
  signal src,dst : natural range 0 to 63 := 0;
  signal promotion : natural range 2 to 5 := 2;
  signal wk,bk,own_king : natural range 0 to 63 := 4;
  signal trial_king : natural range 0 to 63 := 4;
  signal moving,captured : piece_t := x"0";
  signal en_passant,castling,promoting : std_logic := '0';
  signal in_check,done : std_logic := '0';
  signal legal_count : natural range 0 to 256 := 0;
  signal best_move : std_logic_vector(15 downto 0) := (others=>'0');
  signal best_score : integer range -32768 to 32767 := -32768;
  signal candidate_move : std_logic_vector(15 downto 0);
  type candidates_t is array(0 to 511) of std_logic_vector(143 downto 0);
  signal candidates : candidates_t;
  signal candidate_word : std_logic_vector(143 downto 0);
  signal candidate_index : natural range 0 to 511 := 0;
  signal candidate_we : std_logic := '0';
  signal candidate_write_index : natural range 0 to 511 := 0;
  signal candidate_bank,published_bank : natural range 0 to 1 := 0;
  signal completed_count : natural range 0 to 256 := 0;
  signal completed_move : std_logic_vector(15 downto 0) := (others=>'0');
  signal completed_score : integer range -32768 to 32767 := -32768;
  signal candidate_write_data : std_logic_vector(143 downto 0);
  attribute ramstyle of candidates : signal is "M9K";
  signal response_kind : natural range 0 to 18 := 0;
  signal page : natural range 0 to 63 := 0;
  signal response_status_i : natural range 0 to 3 := 0;
  signal elapsed,generation : unsigned(31 downto 0) := (others=>'0');
  signal neuron_index : natural range 0 to 63 := 0;
  signal load_index,load_wk,load_bk : natural range 0 to 63 := 0;
  signal load_white_kings,load_black_kings : natural range 0 to 2 := 0;
  signal load_invalid : std_logic := '0';
  signal relax_left : natural range 0 to 255 := 0;
  signal relax_timer : unsigned(19 downto 0) := (others=>'0');
  signal divider : unsigned(15 downto 0) := (others=>'0');
  signal old_keys : std_logic_vector(3 downto 0) := (others=>'0');
  signal last_token : std_logic_vector(79 downto 0) := (others=>'0');
  signal have_token : std_logic := '0';
  signal cached_status : natural range 0 to 3 := 0;
  signal ack : byte_t := x"00";
  signal score_capture,score_danger,score_field,score_noise : integer range -131072 to 131071 := 0;
  signal read_byte : byte_t;
begin
  assert CLOCK_DIVIDE>=4
    report "Search RAM pipelines and timing constraints require a divide of at least four" severity failure;
  storage : entity work.chess_search_memory port map(clk=>clk,
    queue_we=>queue_we,queue_write_address=>queue_write_address,queue_read_address=>queue_read_address,
    queue_write_data=>queue_write_data,queue_data=>queue_data,
    cache_we=>cache_we,cache_write_address=>cache_write_address,cache_read_address=>cache_read_address,
    cache_write_data=>cache_write_data,cache_data=>cache_data,
    history_we=>history_we,history_write_address=>history_write_address,history_read_address=>history_read_address,
    history_write_data=>history_write_data,history_data=>history_data,
    hash_piece=>hash_piece,hash_square=>search_index,hash_data=>hash_data);
  hash_piece<=b(search_index);
  queue_read_address<=search_sp*SEARCH_MOVES+search_scan;
  cache_read_address<=to_integer(node_hash(search_sp)(CACHE_INDEX_BITS-1 downto 0));
  history_read_address<=src*64+dst;
  spatial : entity work.chess_spatial port map(board=>b,source=>src,
    white_attack=>white_a,black_attack=>black_a,reachable=>reach);
  active_turn <= node_turn(search_sp) when search_active='1' else turn;
  active_rights <= node_rights(search_sp) when search_active='1' else rights;
  active_ep <= node_ep(search_sp) when search_active='1' else ep;
  active_wk <= node_wk(search_sp) when search_active='1' else wk;
  active_bk <= node_bk(search_sp) when search_active='1' else bk;
  friend_a <= white_a when active_turn='0' else black_a;
  enemy_a <= black_a when active_turn='0' else white_a;
  own_king <= active_wk when active_turn='0' else active_bk;
  response_status <= response_status_i;
  candidate_move <= '0' & std_logic_vector(to_unsigned(promotion,3)) &
    std_logic_vector(to_unsigned(dst,6)) & std_logic_vector(to_unsigned(src,6)) when promoting='1' else
    "0000" & std_logic_vector(to_unsigned(dst,6)) & std_logic_vector(to_unsigned(src,6));
  panel <= best_move & std_logic_vector(to_unsigned(legal_count,9)) & turn & done & in_check &
    std_logic_vector(to_unsigned(state_t'pos(state) mod 16,4));
  activity(16)<=turn;
  activity(17)<='1' when state/=IDLE else '0';
  activity(15 downto 0)<=field_leds;

  -- A single synchronous read port preserves M9K inference for candidates.
  candidate_index <= published_bank*256+page*4 + (read_address/18 mod 4) when response_kind=14 else
                     published_bank*256+(page mod 16)*16 + (read_address/4 mod 16);
  route_address <= policy_boot_index mod 64 when state=BOOT_POLICY else
                   route_index when state=LOAD_ROUTES else neuron_index;
  process(clk) begin
    if rising_edge(clk) then
      read_data<=read_byte;
      if candidate_we='1' then candidates(candidate_write_index)<=candidate_write_data; end if;
      candidate_word <= candidates(candidate_index);
      route_q <= route_table(route_address);
      route_host_q <= route_table((read_address+48) mod 64);
      snapshot_q <= snapshot_table((read_address+48) mod 64);
      if phase=0 then
        if state=BOOT_POLICY and policy_boot_index<64 then route_table(route_address)<=x"FF";
        elsif state=LOAD_ROUTES then route_table(route_address)<=packet_rx(17+route_index); end if;
      end if;
      if mem_cell_we='1' then snapshot_table(neuron_index)<=mem_cell_data; end if;
      search_q <= search_stack(search_sp*64+search_index);
      if state=SEARCH_SAVE and phase=0 then
        search_stack(search_sp*64+search_index)<=b(search_index);
      end if;
      if rx_we='1' then rx(rx_address)<=rx_data; end if;
    end if;
  end process;

  -- True dual-port M9K tables. Native-clock RAM reads settle between common
  -- chess enables; these output registers are deliberately not multicycled.
  process(state,neuron_index,neuron_direction,neuron_result,policy_page,policy_index,policy_boot_index,read_address,response_kind,dst)
    variable x,y : integer;
  begin
    cell_address_a<=dst;
    if state=RELAX and neuron_direction<8 then
      x:=neuron_index mod 8+DX(neuron_direction); y:=neuron_index/8+DY(neuron_direction);
      cell_address_a<=0;
      if x>=0 and x<8 and y>=0 and y<8 then cell_address_a<=y*8+x; end if;
    end if;
    table_address_a<=16+neuron_direction;
    if state=BOOT_POLICY then table_address_a<=policy_boot_index;
    elsif state=LOAD_POLICY then table_address_a<=policy_page*64+policy_index;
    elsif response_kind=12 then table_address_a<=policy_page*64+(read_address mod 64);
    elsif neuron_direction=9 then table_address_a<=24+(neuron_result+128)/16;
    end if;
  end process;
  neuron_output<=sat(to_integer(signed(mem_policy_a))) when policy(11)(0)='1' else neuron_result;
  mem_policy_we<='1' when (state=LOAD_POLICY or state=BOOT_POLICY) and phase=0 else '0';
  mem_cell_we<='1' when state=RELAX and neuron_direction=9 and phase=0 and relax_timer=0 and relax_left>0 else '0';
  mem_policy_data<=INIT_POLICY(policy_boot_index) when state=BOOT_POLICY else packet_rx(policy_index+2);
  mem_policy_b_address<=64+neuron_index;
  mem_cell_data<=std_logic_vector(to_signed(neuron_output,8));
  cell_memory : entity work.chess_cell_memory port map(clk=>clk,policy_we=>mem_policy_we,cell_we=>mem_cell_we,
    policy_a=>table_address_a,policy_b=>mem_policy_b_address,cell_a=>cell_address_a,cell_b=>neuron_index,
    policy_data=>mem_policy_data,cell_data=>mem_cell_data,
    policy_q_a=>mem_policy_a,policy_q_b=>mem_policy_b,cell_q_a=>mem_field_a,cell_q_b=>mem_field_b);

  process(all)
    variable n,v : integer;
    variable word32 : std_logic_vector(31 downto 0);
  begin
    n:=read_address; read_byte<=x"00"; v:=0; word32:=(others=>'0');
    case response_kind is
      when 0 =>
        case n is
          when 0=>read_byte<=x"53"; when 1=>read_byte<=x"43"; when 2=>read_byte<=x"46"; when 3=>read_byte<=x"31";
          when 4=>if state/=IDLE then read_byte<=x"01"; end if;
          when 5=>read_byte<="0000000"&done;
          when 6=>read_byte<="0000000"&in_check;
          when 7=>read_byte<="0000000"&turn;
          when 8=>read_byte<=oct(legal_count/256); when 9=>read_byte<=oct(legal_count);
          when 10=>read_byte<=best_move(15 downto 8); when 11=>read_byte<=best_move(7 downto 0);
          when 12=>word32:=std_logic_vector(to_signed(best_score,32)); read_byte<=word32(15 downto 8); when 13=>read_byte<=oct(best_score);
          when 14=>read_byte<=oct(state_t'pos(state)); when 15=>read_byte<=x"04";
          when 16 to 19=>read_byte<=std_logic_vector(elapsed(31-(n-16)*8 downto 24-(n-16)*8));
          when 20 to 23=>read_byte<=std_logic_vector(generation(31-(n-20)*8 downto 24-(n-20)*8));
          when 24 to 27=>read_byte<=std_logic_vector(rng(31-(n-24)*8 downto 24-(n-24)*8));
          when 28=>read_byte<=oct(search_iteration); when 29=>read_byte<=oct(search_completed);
          when 30=>read_byte<=oct(history_count); when 31=>read_byte<=x"0F";
          when others=>null;
        end case;
      when 1=>read_byte<=ack;
      when 4=>
        if n<8 then read_byte<=white_map(n*8+7 downto n*8);
        elsif n<16 then read_byte<=black_map((n-8)*8+7 downto (n-8)*8);
        elsif n<80 then
          if field_valid(n-16)='1' then read_byte<=snapshot_q; end if;
        end if;
      when 5=>
        if n<64 then read_byte<="0000"&base(n);
        elsif n=64 then read_byte<="0000000"&turn;
        elsif n=65 then read_byte<="0000"&rights;
        elsif n=66 then read_byte<=oct(ep); end if;
      when 6=>if n<16 then read_byte<=cfg(n); elsif n<80 then read_byte<=route_host_q; end if;
      when 7=>
        read_byte<=candidate_word(143-(n mod 4)*8 downto 136-(n mod 4)*8);
      when 12=>
        if n<64 then read_byte<=mem_policy_a; end if;
      when 14=>
        read_byte<=candidate_word(143-(n mod 18)*8 downto 136-(n mod 18)*8);
      when 18=>
        if n<4 then read_byte<=std_logic_vector(search_nodes(31-n*8 downto 24-n*8));
        elsif n<8 then read_byte<=std_logic_vector(search_cutoffs(31-(n-4)*8 downto 24-(n-4)*8));
        elsif n=8 then read_byte<=policy(10);
        elsif n=9 then
          if policy(15)(0)='1' then read_byte<=policy(41); end if;
        elsif n=10 then read_byte<=oct(search_completed);
        elsif n=11 then read_byte<="000000"&policy(42)(0)&search_timed_out;
        elsif n<16 then read_byte<=std_logic_vector(search_cache_hits(31-(n-12)*8 downto 24-(n-12)*8));
        elsif n<20 then read_byte<=std_logic_vector(search_cache_stores(31-(n-16)*8 downto 24-(n-16)*8));
        end if;
      when others=>null;
    end case;
  end process;

  process(clk)
    variable sub,len,n,k,x,y,neighbor,excitation,noise,total,delta,score : integer;
    variable valid,pawn_double,pawn_ep,castle_ok,king_safe,mutating,duplicate : boolean;
    variable p,t : piece_t;
    variable temp : board_t;
    variable friend_map,enemy_map : std_logic_vector(63 downto 0);
    variable new_rights : std_logic_vector(3 downto 0);
    variable kings_w,kings_b,king_w_square,king_b_square : integer;
    variable seed32 : unsigned(31 downto 0);
    variable neighbor_s,total_s,old_s,excitation_s : signed(13 downto 0);
    variable local_noise : signed(4 downto 0);
    variable weight_product : signed(15 downto 0);
    variable liability : integer range 0 to 2000;
    variable position_delta : integer range -8192 to 8191;
    variable habit : integer range -2048 to 2047;
    variable capture_part,safety_part,field_part : integer range -32768 to 32767;
    variable progress_part : integer range -65536 to 65535;
    variable our_piece,our_attack,their_attack : boolean;
    variable own_k,enemy_k : natural range 0 to 63;
    variable next_static,search_part,search_depth,prom_kind : integer;
    variable tactical,consider_move : boolean;
    variable packed_move : std_logic_vector(15 downto 0);
    variable order_score,mg,eg,ph,file_index,white_bonus,black_bonus,remaining_depth,remaining_q : integer;
    variable white_passed,black_passed,repeated : boolean;
    variable next_hash : hash_t;
    variable picked : std_logic_vector(31 downto 0);
    variable picked_index : natural range 0 to SEARCH_MOVES-1;
    variable cache_word : std_logic_vector(127 downto 0);
  begin
    if rising_edge(clk) then
      response_done<='0'; candidate_we<='0'; queue_we<='0'; cache_we<='0'; history_we<='0';
      divider<=divider+1;
      if phase=CLOCK_DIVIDE-1 then phase<=0; else phase<=phase+1; end if;
      if command='0' then command_seen<='0'; end if;
      -- Shared PRNG; serial field updates sample different cycles.
      rng <= rng(30 downto 0)&(rng(31) xor rng(21) xor rng(1) xor rng(0));
      if reset='1' then
        phase<=0; command_seen<='0'; command_pending<='0'; old_keys<=(others=>'0');
        state<=IDLE;
        if policy_initialized='0' then state<=BOOT_POLICY; policy_boot_index<=0; end if;
        base<=initial_board; b<=initial_board; turn<='0'; rights<="1111"; ep<=64;
        wk<=4; bk<=60; field_valid<=(others=>'0'); field_leds<=(others=>'0');
        done<='0'; in_check<='0'; legal_count<=0; best_score<=-32768; best_move<=(others=>'0');
        generation<=(others=>'0'); elapsed<=(others=>'0'); rng<=x"D0E2C35F"; have_token<='0';
        history_count<=0; nonpawn_count<=14; neuron_direction<=0; neighbor_accum<=(others=>'0');
        neuron_old<=(others=>'0'); neuron_bias<=(others=>'0');
        search_active<='0'; search_sp<=0; search_nodes<=(others=>'0'); search_cutoffs<=(others=>'0');
        search_running<='0'; search_has_completed<='0'; search_completed<=0; search_iteration<=0;
        search_timed_out<='0'; candidate_bank<=0; published_bank<=0;
        search_cache_hits<=(others=>'0'); search_cache_stores<=(others=>'0');
      elsif phase=0 then
        old_keys<=keys;
        -- Freeze the received frame at the chess enable boundary before any
        -- decoding or arithmetic. Native RX remains single-cycle constrained;
        -- every evaluator operand now comes from an enabled register bank.
        if command='1' and command_seen='0' then
          packet_rx<=rx; packet_length<=request_length; packet_token<=request_token;
          command_seen<='1'; command_pending<='1';
        end if;
        if state/=IDLE then elapsed<=elapsed+CLOCK_DIVIDE; end if;
        -- Every register below advances only on this common enable. The SDC
        -- gives only these source/destination banks CLOCK_DIVIDE setup cycles.
        -- Host byte reception, RAM readout and command strobes stay at 50 MHz.
        -- Registered spatial memory is distributed; a shared neuron ALU
        -- scans it in Gauss-Seidel order. All movement/attack cells remain
        -- concurrent. The shared PRNG saves logic for the search stack.
        if state=RELAX and relax_timer=0 and relax_left>0 then
            n:=neuron_index;
            if neuron_direction<8 then
              -- Capture RAM operands early in the cell's existing microsteps.
              -- The activation arithmetic then runs entirely between CE banks.
              if neuron_direction=0 then
                neuron_old<=(others=>'0');
                if field_valid(n)='1' then neuron_old<=signed(mem_field_b); end if;
                neuron_bias<=signed(mem_policy_b);
              end if;
              x:=n mod 8+DX(neuron_direction); y:=n/8+DY(neuron_direction);
              if x>=0 and x<8 and y>=0 and y<8 and route_q(neuron_direction)='1' and field_valid(cell_address_a)='1' then
                weight_product:=signed(mem_field_a)*signed(mem_policy_a);
                neighbor_accum<=neighbor_accum+resize(shift_right(weight_product,6),14);
              end if;
              neuron_direction<=neuron_direction+1;
            elsif neuron_direction=8 then
            neighbor_s:=neighbor_accum; neighbor_accum<=(others=>'0'); neuron_direction<=0;
            old_s:=resize(neuron_old,14);
            excitation_s:=(others=>'0');
            if friend_a(n)='1' then excitation_s:=resize(signed('0' & cfg(1)(7 downto 1)),14); end if;
            if enemy_a(n)='1' then excitation_s:=excitation_s-resize(signed('0' & cfg(2)(7 downto 1)),14); end if;
            local_noise:=resize(signed(rng(3 downto 0)),5);
            if rng(7 downto 0)>=unsigned(cfg(0)) then local_noise:=(others=>'0'); end if;
            total_s:=old_s-shift_right(old_s,to_integer(unsigned(policy(14)(2 downto 0))))+
                     shift_right(neighbor_s,2)+excitation_s+resize(local_noise,14)+resize(neuron_bias,14);
            if cfg(3)(0)='1' then total_s:=total_s+shift_right(old_s,3); end if;
            if cfg(3)(1)='1' then total_s:=total_s-shift_right(neighbor_s,1); end if;
            if abs(total_s)<resize(signed('0'&cfg(3)(7 downto 2)),14) then total_s:=(others=>'0'); end if;
            neuron_result<=sat(to_integer(total_s)); neuron_direction<=9;
            else
            field_valid(n)<='1'; neuron_direction<=0;
            if n mod 8=0 then
              field_leds(n/8)<='0'; field_leds(n/8+8)<='0';
              if neuron_output>32 then field_leds(n/8)<='1'; end if;
              if neuron_output< -32 then field_leds(n/8+8)<='1'; end if;
            end if;
            if neuron_index=63 then neuron_index<=0; else neuron_index<=neuron_index+1; end if;
            end if;
        end if;
        case state is
          when BOOT_POLICY=>
            if policy_boot_index=127 then policy_initialized<='1'; state<=IDLE;
            else policy_boot_index<=policy_boot_index+1; end if;
          when LOAD_SCAN=>
            p:=packet_rx(load_index+1)(3 downto 0); b(load_index)<=p;
            if unsigned(packet_rx(load_index+1))>14 or p=x"7" or p=x"8" then load_invalid<='1'; end if;
            if kind(p)=1 and (load_index/8=0 or load_index/8=7) then load_invalid<='1'; end if;
            if p=x"6" then
              load_wk<=load_index;
              if load_white_kings<2 then load_white_kings<=load_white_kings+1; end if;
            end if;
            if p=x"E" then
              load_bk<=load_index;
              if load_black_kings<2 then load_black_kings<=load_black_kings+1; end if;
            end if;
            if kind(p)>=2 and kind(p)<=5 then load_nonpawn<=load_nonpawn+1; end if;
            if load_index=63 then state<=LOAD_FINISH; else load_index<=load_index+1; end if;
          when LOAD_FINISH=>
            response_done<='1'; state<=IDLE;
            if load_invalid='1' or load_white_kings/=1 or load_black_kings/=1 then
              response_status_i<=3; cached_status<=3; b<=base;
            else
              wk<=load_wk; bk<=load_bk; base<=b; nonpawn_count<=load_nonpawn;
              turn<=packet_rx(65)(0); rights<=packet_rx(66)(3 downto 0); ep<=to_integer(unsigned(packet_rx(67)));
              done<='0'; in_check<='0'; legal_count<=0; field_valid<=(others=>'0'); field_leds<=(others=>'0'); generation<=generation+1; history_count<=0;
            end if;
          when IDLE=>
            b<=base; white_map<=white_a; black_map<=black_a; in_check<=enemy_a(own_king);
            if keys(1)='1' and old_keys(1)='0' then state<=SNAPSHOT; done<='0'; end if;
          when SNAPSHOT=>
            search_active<='0'; search_nodes<=(others=>'0'); search_cutoffs<=(others=>'0');
            search_running<='1'; search_has_completed<='0'; search_completed<=0; search_timed_out<='0';
            search_iteration<=0; if unsigned(policy(10))>=2 then search_iteration<=2; end if;
            candidate_bank<=1-published_bank;
            search_limit<=resize(resize(unsigned(policy(40)),32)*to_unsigned(CLOCK_HZ,32),32);
            search_epoch<=search_epoch+1;
            search_cache_hits<=(others=>'0'); search_cache_stores<=(others=>'0');
            node_killer1<=(others=>(others=>'0')); node_killer2<=(others=>(others=>'0'));
            white_map<=white_a; black_map<=black_a; in_check<=enemy_a(own_king);
            legal_count<=0; src<=0; dst<=0; promotion<=2; best_score<=-32768;
            best_move<=(others=>'0'); elapsed<=(others=>'0');
            neuron_index<=0; neuron_direction<=0; neighbor_accum<=(others=>'0');
            relax_left<=to_integer(unsigned(cfg(4))); relax_timer<=(others=>'0');
            audit_trial<='0'; state<=AUDIT_RESET;
            if search_epoch=x"FFFF" then search_clear_index<=0; state<=CACHE_CLEAR; end if;
          when CACHE_CLEAR=>
            cache_we<='1'; cache_write_address<=search_clear_index; cache_write_data<=(others=>'0');
            if search_clear_index=CACHE_ENTRIES-1 then state<=AUDIT_RESET;
            else search_clear_index<=search_clear_index+1; end if;
          when RELAX=>
            if relax_timer/=0 then relax_timer<=relax_timer-1;
            elsif relax_left=0 then state<=PICK;
            elsif neuron_index=63 and neuron_direction=9 then relax_left<=relax_left-1; relax_timer<=shift_left(resize(unsigned(cfg(11)),20),12)/CLOCK_DIVIDE; end if;
          when LOAD_ROUTES=>
            if route_index=63 then state<=IDLE; response_done<='1';
            else route_index<=route_index+1; end if;
          when LOAD_POLICY=>
            if policy_page=0 and policy_index<43 then policy(policy_index)<=packet_rx(policy_index+2); end if;
            if policy_index=63 then state<=IDLE; response_done<='1';
            else policy_index<=policy_index+1; end if;
          when AUDIT_RESET=>
            audit_index<=0; audit_own_max<=0; audit_enemy_max<=0; audit_own_sum<=0; audit_enemy_sum<=0;
            audit_position<=0; audit_static<=0; audit_minor_home<=0; state<=AUDIT_CELL;
          when AUDIT_CELL=>
            p:=b(audit_index); k:=kind(p); our_piece:=p(3)=turn;
            our_attack:=friend_a(audit_index)='1'; their_attack:=enemy_a(audit_index)='1';
            liability:=0;
            if k>=1 and k<=5 then
              if (our_piece and their_attack) or (not our_piece and our_attack) then
                liability:=value(p);
                if (our_piece and our_attack) or (not our_piece and their_attack) then liability:=liability*3/4; end if;
              end if;
              if our_piece then
                audit_own_sum<=audit_own_sum+liability;
                if liability>audit_own_max then audit_own_max<=liability; end if;
              else
                audit_enemy_sum<=audit_enemy_sum+liability;
                if liability>audit_enemy_max then audit_enemy_max<=liability; end if;
              end if;
            end if;
            position_delta:=value(p)*to_integer(unsigned(policy(12)))/16+
                            square_wisdom(p,audit_index,nonpawn_count<=4)*to_integer(unsigned(policy(13)))/16;
            if not our_piece then position_delta:=-position_delta; end if;
            audit_static<=clip16(audit_static+position_delta);
            position_delta:=0;
            if k/=0 then
              position_delta:=square_wisdom(p,audit_index,nonpawn_count<=4);
              if not our_piece then position_delta:=-position_delta; end if;
              if our_piece and (k=2 or k=3) and
                 ((turn='0' and audit_index/8=0) or (turn='1' and audit_index/8=7)) then
                audit_minor_home<=audit_minor_home+1;
              end if;
            end if;
            if our_attack then position_delta:=position_delta+centrality(audit_index)*to_integer(unsigned(policy(8))); end if;
            if their_attack then position_delta:=position_delta-centrality(audit_index)*to_integer(unsigned(policy(8))); end if;
            own_k:=own_king; if audit_trial='1' then own_k:=trial_king; end if;
            enemy_k:=bk; if turn='1' then enemy_k:=wk; end if;
            if nonpawn_count>4 then
              if abs(audit_index mod 8-own_k mod 8)<=1 and abs(audit_index/8-own_k/8)<=1 and their_attack then
                position_delta:=position_delta-to_integer(unsigned(policy(9)));
              end if;
              if abs(audit_index mod 8-enemy_k mod 8)<=1 and abs(audit_index/8-enemy_k/8)<=1 and our_attack then
                position_delta:=position_delta+to_integer(unsigned(policy(9)));
              end if;
            end if;
            audit_position<=audit_position+position_delta;
            if audit_index=63 then state<=AUDIT_DONE; else audit_index<=audit_index+1; end if;
          when AUDIT_DONE=>
            if audit_trial='0' then
              base_own_risk<=audit_own_max+audit_own_sum/4;
              base_enemy_risk<=audit_enemy_max+audit_enemy_sum/4;
              base_position<=audit_position; base_static<=audit_static;
              base_minor_home<=audit_minor_home; state<=RELAX;
            else
              score_safety<=clip16((base_own_risk-audit_own_max-audit_own_sum/4)*to_integer(unsigned(policy(0)))/16+
                (audit_enemy_max+audit_enemy_sum/4-base_enemy_risk)*to_integer(unsigned(policy(1)))/16);
              score_progress<=clip16((audit_position-base_position)*to_integer(unsigned(policy(2)))/8);
              state<=SCORE_MOVE;
            end if;
          when PICK=>
            p:=b(src); t:=b(dst); k:=kind(p); delta:=dst-src;
            valid:=false; pawn_double:=false; pawn_ep:=false; castle_ok:=false;
            friend_map:=friend_a; enemy_map:=enemy_a;
            if k/=0 and p(3)=active_turn and src/=dst and kind(t)/=6 and (kind(t)=0 or t(3)/=active_turn) then
              if k/=1 then valid:=reach(dst)='1';
              else
                if src mod 8=dst mod 8 and kind(t)=0 then
                  if (active_turn='0' and delta=8) or (active_turn='1' and delta=-8) then valid:=true; end if;
                  if active_turn='0' and src/8=1 and delta=16 then pawn_double:=kind(b(src+8))=0; end if;
                  if active_turn='1' and src/8=6 and delta=-16 then pawn_double:=kind(b(src-8))=0; end if;
                elsif reach(dst)='1' then
                  if kind(t)/=0 then valid:=true;
                  elsif dst=active_ep then
                    if active_turn='0' and dst/8=5 then pawn_ep:=b(dst-8)=x"9"; end if;
                    if active_turn='1' and dst/8=2 then pawn_ep:=b(dst+8)=x"1"; end if;
                  end if;
                end if;
                valid:=valid or pawn_double or pawn_ep;
              end if;
              if k=6 and ((active_turn='0' and src=4) or (active_turn='1' and src=60)) then
                n:=0; if active_turn='1' then n:=56; end if;
                if dst=n+6 and active_rights(n/28)='1' then
                  castle_ok:=b(n+7)(2 downto 0)="100" and b(n+7)(3)=active_turn and
                    kind(b(n+5))=0 and kind(b(n+6))=0 and enemy_map(n+4)='0' and enemy_map(n+5)='0';
                elsif dst=n+2 and active_rights(n/28+1)='1' then
                  castle_ok:=b(n)(2 downto 0)="100" and b(n)(3)=active_turn and
                    kind(b(n+1))=0 and kind(b(n+2))=0 and kind(b(n+3))=0 and
                    enemy_map(n+4)='0' and enemy_map(n+3)='0';
                end if;
                valid:=valid or castle_ok;
              end if;
            end if;
            moving<=p; captured<=t; en_passant<='0'; castling<='0'; promoting<='0'; trial_king<=own_king;
            if pawn_ep then en_passant<='1'; captured<=(not active_turn)&"001"; end if;
            if castle_ok then castling<='1'; end if;
            if k=1 and (dst/8=0 or dst/8=7) then promoting<='1'; end if;
            if k=0 or p(3)/=active_turn then
              -- Skip all 64 destinations for an ineligible source.
              dst<=63; promoting<='0'; state<=ADVANCE;
            elsif valid and search_active='1' and search_building='1' then
              packed_move:="0000"&std_logic_vector(to_unsigned(dst,6))&std_logic_vector(to_unsigned(src,6));
              if k=1 and (dst/8=0 or dst/8=7) then packed_move(14 downto 12):=std_logic_vector(to_unsigned(promotion,3)); end if;
              order_score:=512+to_integer(history_data)+square_wisdom(p,dst,false)-square_wisdom(p,src,false);
              if node_killer2(search_sp)=packed_move then order_score:=17000; end if;
              if node_killer1(search_sp)=packed_move then order_score:=18000; end if;
              if kind(t)/=0 or pawn_ep or (k=1 and (dst/8=0 or dst/8=7)) then
                n:=value(t); if pawn_ep then n:=100; end if;
                order_score:=20000+n*16-value(p);
                if k=1 and (dst/8=0 or dst/8=7) then order_score:=order_score+(value(std_logic_vector(to_unsigned(promotion,4)))-100)*8; end if;
              end if;
              if node_hint_valid(search_sp)='1' and node_hint(search_sp)=packed_move then order_score:=65535; end if;
              -- Standard chess has at most 16 pieces per side, so even 16
              -- queens have fewer than 512 pseudo-legal destinations.
              assert node_count(search_sp)<SEARCH_MOVES report "Search move RAM capacity exceeded" severity failure;
              if node_count(search_sp)<SEARCH_MOVES then
                queue_we<='1'; queue_write_address<=search_sp*SEARCH_MOVES+node_count(search_sp);
                queue_write_data<=std_logic_vector(to_unsigned(order_score,16))&packed_move;
                node_count(search_sp)<=node_count(search_sp)+1;
              end if;
              state<=ADVANCE;
            elsif valid then
              -- Once a legal move is known, quiet moves at a quiescent node
              -- need no speculative apply/restore cycle.
              if search_active='1' and search_sp+1>=search_iteration and node_check(search_sp)='0' and
                 node_legal(search_sp)='1' and kind(t)=0 and not pawn_ep and not (k=1 and (dst/8=0 or dst/8=7)) then
                state<=ADVANCE;
              else state<=APPLY; end if;
            else state<=ADVANCE; end if;
          when APPLY | COMMIT_MOVE=>
            temp:=b; if state=COMMIT_MOVE then temp:=base; end if; p:=moving;
            if promoting='1' then p:=active_turn&std_logic_vector(to_unsigned(promotion,3)); end if;
            temp(src):=x"0"; temp(dst):=p;
            if en_passant='1' then
              if active_turn='0' then temp(dst-8):=x"0"; else temp(dst+8):=x"0"; end if;
            end if;
            if castling='1' then
              if dst mod 8=6 then temp(dst-1):=active_turn&"100"; temp(dst+1):=x"0";
              else temp(dst+1):=active_turn&"100"; temp(dst-2):=x"0"; end if;
            end if;
            b<=temp;
            if kind(moving)=6 then trial_king<=dst; end if;
            if state=COMMIT_MOVE then
              for i in 7 downto 1 loop history(i)<=history(i-1); end loop;
              history(0)<=candidate_move;
              if history_count<8 then history_count<=history_count+1; end if;
              n:=nonpawn_count;
              if kind(captured)>=2 and kind(captured)<=5 then n:=n-1; end if;
              if promoting='1' then n:=n+1; end if;
              nonpawn_count<=n;
              base<=temp; turn<=not turn; done<='0'; legal_count<=0; generation<=generation+1; state<=IDLE;
              if kind(moving)=6 then
                if active_turn='0' then wk<=dst; else bk<=dst; end if;
              end if;
              new_rights:=rights;
              if src=4 then new_rights(1 downto 0):="00"; end if;
              if src=60 then new_rights(3 downto 2):="00"; end if;
              if src=0 or dst=0 then new_rights(1):='0'; end if;
              if src=7 or dst=7 then new_rights(0):='0'; end if;
              if src=56 or dst=56 then new_rights(3):='0'; end if;
              if src=63 or dst=63 then new_rights(2):='0'; end if;
              rights<=new_rights; ep<=64;
              if kind(moving)=1 and abs(dst-src)=16 then ep<=(src+dst)/2; end if;
            else state<=SETTLE; end if;
          when SETTLE=>state<=INSPECT;
          when INSPECT=>
            if enemy_a(trial_king)='0' then
              prom_kind:=0; if promoting='1' then prom_kind:=promotion; end if;
              delta:=move_position_delta(moving,captured,src,dst,prom_kind,en_passant,castling,
                       nonpawn_count<=4,to_integer(unsigned(policy(12))),to_integer(unsigned(policy(13))));
              if active_turn/=turn then delta:=-delta; end if;
              if search_active='1' then
                node_legal(search_sp)<='1';
                tactical:=kind(captured)/=0 or promoting='1';
                node_tactical(search_sp)<='0'; if tactical then node_tactical(search_sp)<='1'; end if;
                search_depth:=search_iteration;
                remaining_q:=0; if policy(15)(0)='1' then remaining_q:=to_integer(unsigned(policy(41))); end if;
                consider_move:=search_sp+1<search_depth or node_check(search_sp)='1' or tactical;
                -- Stand-pat cutoffs are legal only after finding an actual
                -- legal move; this preserves mate and stalemate at the horizon.
                valid:=search_sp+1>=search_depth and node_check(search_sp)='0' and
                  ((active_turn=turn and node_best(search_sp)>=node_beta(search_sp)) or
                   (active_turn/=turn and node_best(search_sp)<=node_alpha(search_sp)));
                if valid then search_result<=node_best(search_sp); state<=SEARCH_RETURN;
                elsif search_sp+1>=search_depth+remaining_q and
                      (node_check(search_sp)='0' or search_sp+1>=search_depth+remaining_q+1) then
                  search_result<=node_static(search_sp); state<=SEARCH_RETURN;
                elsif consider_move then
                  if search_sp<SEARCH_LEVELS-1 then
                    cursor_src(search_sp)<=src; cursor_dst(search_sp)<=dst;
                    cursor_promotion(search_sp)<=promotion; cursor_promoting(search_sp)<=promoting;
                    node_turn(search_sp+1)<=not active_turn;
                    node_rights(search_sp+1)<=updated_rights(active_rights,src,dst);
                    node_ep(search_sp+1)<=64;
                    if kind(moving)=1 and abs(dst-src)=16 then node_ep(search_sp+1)<=(src+dst)/2; end if;
                    node_wk(search_sp+1)<=active_wk; node_bk(search_sp+1)<=active_bk;
                    if kind(moving)=6 then
                      if active_turn='0' then node_wk(search_sp+1)<=dst; else node_bk(search_sp+1)<=dst; end if;
                    end if;
                    node_alpha(search_sp+1)<=node_alpha(search_sp); node_beta(search_sp+1)<=node_beta(search_sp);
                    search_sp<=search_sp+1; search_index<=0; state<=SEARCH_SAVE;
                  else search_result<=node_static(search_sp); state<=SEARCH_RETURN; end if;
                else search_returning<='0'; search_index<=0; state<=SEARCH_RECALL_WAIT; end if;
              else
                trial_static<=clip16(base_static+delta);
                -- Root-only recurrent and whole-board priors remain inspectable.
                score_capture<=value(captured)*to_integer(unsigned(cfg(5)))/8;
                n:=0;
                if enemy_a(dst)='1' then
                  n:=value(b(dst)); if friend_a(dst)='1' then n:=n*3/4; end if;
                end if;
                score_danger<=n*to_integer(unsigned(cfg(6)))/8;
                n:=0; if field_valid(dst)='1' then n:=to_integer(signed(mem_field_a)); end if;
                score_field<=n*to_integer(unsigned(cfg(7)))/8;
                n:=to_integer(rng(7 downto 0) and unsigned(cfg(0)));
                if switches(17)='1' then n:=to_integer(rng(7 downto 0) and unsigned(switches(7 downto 0))); end if;
                score_noise<=n; audit_trial<='1'; state<=AUDIT_RESET;
              end if;
            elsif search_active='1' then
              search_returning<='0'; search_index<=0; state<=SEARCH_RECALL_WAIT;
            else state<=RESTORE; end if;
          when SCORE_MOVE=>
            capture_part:=clip16(score_capture); safety_part:=clip16(score_safety-score_danger);
            progress_part:=score_progress; field_part:=clip16(score_field); habit:=0;
            if kind(moving)>=2 and kind(moving)<=5 then
              progress_part:=progress_part+to_integer(unsigned(cfg(10+kind(moving))));
            end if;
            if (turn='0' and black_map(src)='1') or (turn='1' and white_map(src)='1') then
              progress_part:=progress_part+to_integer(unsigned(cfg(8)));
            end if;
            if kind(moving)=1 then progress_part:=progress_part+abs(dst-src)/8*to_integer(unsigned(cfg(9))); end if;
            if kind(moving)=2 or kind(moving)=3 then
              if (turn='0' and src/8=0 and dst/8/=0) or (turn='1' and src/8=7 and dst/8/=7) then
                progress_part:=progress_part+to_integer(unsigned(policy(5)));
              elsif (turn='0' and src/8/=0 and dst/8=0) or (turn='1' and src/8/=7 and dst/8=7) then
                progress_part:=progress_part-to_integer(unsigned(policy(5)));
              end if;
            end if;
            if promoting='1' then capture_part:=clip16(capture_part+value(b(dst))-100); end if;
            if (friend_a(wk)='1' and turn='1') or (friend_a(bk)='1' and turn='0') then
              progress_part:=progress_part+to_integer(unsigned(cfg(10)));
            end if;
            if castling='1' then progress_part:=progress_part+to_integer(unsigned(policy(6))); end if;
            if kind(moving)=5 and base_minor_home>0 and nonpawn_count>8 then
              progress_part:=progress_part-to_integer(unsigned(policy(7)))*base_minor_home;
            end if;
            -- Historical moves are factual host input; all habit scoring is hardware.
            if kind(captured)=0 and promoting='0' then
              for i in 0 to 3 loop
                if i*2+1<history_count then
                  if history(i*2+1)(5 downto 0)=std_logic_vector(to_unsigned(dst,6)) and
                     history(i*2+1)(11 downto 6)=std_logic_vector(to_unsigned(src,6)) then
                    habit:=habit-to_integer(unsigned(policy(3)))/(i+1);
                  end if;
                  if history(i*2+1)(11 downto 0)=candidate_move(11 downto 0) then
                    habit:=habit-to_integer(unsigned(policy(4)))/(i+1);
                  end if;
                end if;
              end loop;
            end if;
            if in_check='1' then habit:=habit/4; end if;
            progress_part:=clip16(progress_part); habit:=clip16(habit);
            if unsigned(policy(10))>=2 then
              -- Search dominates material decisions; the old spatial circuit
              -- supplies bounded root preferences, not a second search engine.
              capture_part:=capture_part/32; safety_part:=safety_part/32;
              progress_part:=progress_part/8; field_part:=field_part/8; habit:=habit/4;
              search_parts<=std_logic_vector(to_signed(capture_part,16))&std_logic_vector(to_signed(safety_part,16))&
                std_logic_vector(to_signed(progress_part,16))&std_logic_vector(to_signed(field_part,16))&
                std_logic_vector(to_signed(habit,16))&std_logic_vector(to_signed(score_noise/4,16));
              search_root_move<=candidate_move; search_active<='1'; search_sp<=0; search_index<=0;
              node_static(0)<=trial_static; if trial_static>25000 then node_static(0)<=25000; elsif trial_static< -25000 then node_static(0)<=-25000; end if; node_turn(0)<=not turn;
              node_rights(0)<=updated_rights(rights,src,dst); node_ep(0)<=64;
              if kind(moving)=1 and abs(dst-src)=16 then node_ep(0)<=(src+dst)/2; end if;
              node_wk(0)<=wk; node_bk(0)<=bk;
              if kind(moving)=6 then
                if turn='0' then node_wk(0)<=dst; else node_bk(0)<=dst; end if;
              end if;
              node_alpha(0)<=-30000; node_beta(0)<=30000; state<=SEARCH_SAVE;
            else
              search_parts<=std_logic_vector(to_signed(capture_part,16))&std_logic_vector(to_signed(safety_part,16))&
                std_logic_vector(to_signed(progress_part,16))&std_logic_vector(to_signed(field_part,16))&
                std_logic_vector(to_signed(habit,16))&std_logic_vector(to_signed(score_noise,16));
              search_root_move<=candidate_move; search_delta_score<=0; state<=SEARCH_SUM;
            end if;
          when SEARCH_SAVE=>
            p:=b(search_index); k:=kind(p); file_index:=search_index mod 8;
            mg:=value(p); if k=6 then mg:=0; end if;
            mg:=mg*to_integer(unsigned(policy(12)))/16;
            eg:=mg+square_wisdom(p,search_index,true)*to_integer(unsigned(policy(13)))/16;
            mg:=mg+square_wisdom(p,search_index,false)*to_integer(unsigned(policy(13)))/16;
            if p(3)='1' then mg:=-mg; eg:=-eg; end if;
            if k=1 then
              -- Pawn shelter matters in the middlegame, not in king endings.
              if p(3)='0' and abs(file_index-active_wk mod 8)<=1 and
                 (search_index/8=active_wk/8+1 or search_index/8=active_wk/8+2) then mg:=mg+10; end if;
              if p(3)='1' and abs(file_index-active_bk mod 8)<=1 and
                 (search_index/8=active_bk/8-1 or search_index/8=active_bk/8-2) then mg:=mg-10; end if;
            end if;
            ph:=0; if k=2 or k=3 then ph:=1; elsif k=4 then ph:=2; elsif k=5 then ph:=4; end if;
            if search_index=0 then
              eval_mg<=mg; eval_eg<=eg; eval_phase<=ph;
              eval_white_pawns<=(others=>0); eval_black_pawns<=(others=>0);
              eval_white_rooks<=(others=>0); eval_black_rooks<=(others=>0);
              eval_white_min<=(others=>7); eval_black_min<=(others=>7);
              eval_white_max<=(others=>0); eval_black_max<=(others=>0);
              eval_white_bishops<=0; eval_black_bishops<=0;
              eval_minors<=0; eval_knights<=0; eval_heavy<='0'; eval_bishop_colors<="00";
              next_hash:=position_salt(active_turn,active_rights,active_ep) xor hash_data;
            else
              eval_mg<=eval_mg+mg; eval_eg<=eval_eg+eg; eval_phase<=eval_phase+ph;
              next_hash:=search_hash_acc xor hash_data;
            end if;
            search_hash_acc<=next_hash;
            if k=1 or k=4 or k=5 then eval_heavy<='1'; end if;
            if k=2 or k=3 then
              n:=eval_minors; if search_index=0 then n:=0; end if;
              eval_minors<=n+1;
              if k=2 then
                n:=eval_knights; if search_index=0 then n:=0; end if; eval_knights<=n+1;
              else eval_bishop_colors((search_index/8+search_index mod 8) mod 2)<='1'; end if;
            end if;
            if k=1 then
              if p(3)='0' then
                eval_white_pawns(file_index)<=eval_white_pawns(file_index)+1;
                if search_index/8<eval_white_min(file_index) then eval_white_min(file_index)<=search_index/8; end if;
                if search_index/8>eval_white_max(file_index) then eval_white_max(file_index)<=search_index/8; end if;
              else
                eval_black_pawns(file_index)<=eval_black_pawns(file_index)+1;
                if search_index/8<eval_black_min(file_index) then eval_black_min(file_index)<=search_index/8; end if;
                if search_index/8>eval_black_max(file_index) then eval_black_max(file_index)<=search_index/8; end if;
              end if;
            elsif k=3 then
              n:=0; if search_index/=0 then
                n:=eval_white_bishops; if p(3)='1' then n:=eval_black_bishops; end if;
              end if;
              if p(3)='0' then eval_white_bishops<=n+1; else eval_black_bishops<=n+1; end if;
            elsif k=4 then
              n:=0; if search_index/=0 then
                n:=eval_white_rooks(file_index); if p(3)='1' then n:=eval_black_rooks(file_index); end if;
              end if;
              if p(3)='0' then eval_white_rooks(file_index)<=n+1; else eval_black_rooks(file_index)<=n+1; end if;
            end if;
            if search_index=63 then
              node_hash(search_sp)<=next_hash; eval_file<=0; state<=EVAL_PAWNS;
            else search_index<=search_index+1; end if;
          when EVAL_PAWNS=>
            n:=eval_file; mg:=0; eg:=0; white_bonus:=0; black_bonus:=0;
            white_passed:=eval_white_pawns(n)>0; black_passed:=eval_black_pawns(n)>0;
            if eval_black_pawns(n)>0 and eval_black_max(n)>eval_white_max(n) then white_passed:=false; end if;
            if eval_white_pawns(n)>0 and eval_white_min(n)<eval_black_min(n) then black_passed:=false; end if;
            if n>0 then
              white_bonus:=white_bonus+eval_white_pawns(n-1); black_bonus:=black_bonus+eval_black_pawns(n-1);
              if eval_black_pawns(n-1)>0 and eval_black_max(n-1)>eval_white_max(n) then white_passed:=false; end if;
              if eval_white_pawns(n-1)>0 and eval_white_min(n-1)<eval_black_min(n) then black_passed:=false; end if;
            end if;
            if n<7 then
              white_bonus:=white_bonus+eval_white_pawns(n+1); black_bonus:=black_bonus+eval_black_pawns(n+1);
              if eval_black_pawns(n+1)>0 and eval_black_max(n+1)>eval_white_max(n) then white_passed:=false; end if;
              if eval_white_pawns(n+1)>0 and eval_white_min(n+1)<eval_black_min(n) then black_passed:=false; end if;
            end if;
            if white_bonus=0 then mg:=mg-eval_white_pawns(n)*12; eg:=eg-eval_white_pawns(n)*18; end if;
            if black_bonus=0 then mg:=mg+eval_black_pawns(n)*12; eg:=eg+eval_black_pawns(n)*18; end if;
            if eval_white_pawns(n)>1 then mg:=mg-(eval_white_pawns(n)-1)*14; eg:=eg-(eval_white_pawns(n)-1)*20; end if;
            if eval_black_pawns(n)>1 then mg:=mg+(eval_black_pawns(n)-1)*14; eg:=eg+(eval_black_pawns(n)-1)*20; end if;
            if white_passed then k:=eval_white_max(n); mg:=mg+k*k*3; eg:=eg+k*k*8; end if;
            if black_passed then k:=7-eval_black_min(n); mg:=mg-k*k*3; eg:=eg-k*k*8; end if;
            if eval_white_pawns(n)=0 then
              mg:=mg+eval_white_rooks(n)*14;
              if abs(n-active_wk mod 8)<=1 then mg:=mg-12; end if;
            end if;
            if eval_black_pawns(n)=0 then
              mg:=mg-eval_black_rooks(n)*14;
              if abs(n-active_bk mod 8)<=1 then mg:=mg+12; end if;
            end if;
            if eval_white_pawns(n)=0 and eval_black_pawns(n)=0 then mg:=mg+(eval_white_rooks(n)-eval_black_rooks(n))*12; end if;
            if n=0 then
              if eval_white_bishops>=2 then mg:=mg+28; eg:=eg+40; end if;
              if eval_black_bishops>=2 then mg:=mg-28; eg:=eg-40; end if;
            end if;
            eval_mg<=eval_mg+mg*to_integer(unsigned(policy(13)))/16;
            eval_eg<=eval_eg+eg*to_integer(unsigned(policy(13)))/16;
            if eval_file=7 then state<=EVAL_BLEND; else eval_file<=eval_file+1; end if;
          when EVAL_BLEND=>
            ph:=eval_phase; if ph>24 then ph:=24; end if;
            eval_blend_mg<=eval_mg*ph; eval_blend_eg<=eval_eg*(24-ph); state<=EVAL_DONE;
          when EVAL_DONE=>
            score:=(eval_blend_mg+eval_blend_eg)/24; if turn='1' then score:=-score; end if;
            if score>25000 then score:=25000; elsif score< -25000 then score:=-25000; end if;
            node_draw(search_sp)<='0';
            if eval_heavy='0' and (eval_minors<=1 or (eval_knights=0 and eval_bishop_colors/="11")) then
              node_draw(search_sp)<='1'; score:=0;
            end if;
            node_static(search_sp)<=score; state<=SEARCH_BEGIN;
          when SEARCH_BEGIN=>
            node_cache_word<=cache_data;
            search_nodes<=search_nodes+1; node_legal(search_sp)<='0'; node_check(search_sp)<=enemy_a(own_king);
            node_count(search_sp)<=0; node_hint_valid(search_sp)<='0'; node_cached(search_sp)<='0'; node_repetition(search_sp)<='0';
            node_best_move(search_sp)<=(others=>'0');
            node_start_alpha(search_sp)<=node_alpha(search_sp); node_start_beta(search_sp)<=node_beta(search_sp);
            node_best(search_sp)<=30000;
            if active_turn=turn then node_best(search_sp)<=-30000; end if;
            -- At the quiescent frontier allow standing pat only out of check.
            if search_sp+1>=search_iteration and enemy_a(own_king)='0' then
              node_best(search_sp)<=node_static(search_sp);
              if active_turn=turn and node_static(search_sp)>node_alpha(search_sp) then node_alpha(search_sp)<=node_static(search_sp); end if;
              if active_turn/=turn and node_static(search_sp)<node_beta(search_sp) then node_beta(search_sp)<=node_static(search_sp); end if;
            end if;
            state<=CACHE_PROBE;
          when CACHE_PROBE=>
            repeated:=false;
            for i in 0 to SEARCH_LEVELS-1 loop
              if i<search_sp and node_hash(i)=node_hash(search_sp) then repeated:=true; end if;
            end loop;
            search_building<='1'; src<=0; dst<=0; promotion<=2; promoting<='0'; state<=PICK;
            remaining_depth:=search_iteration-search_sp-1; if remaining_depth<0 then remaining_depth:=0; end if;
            remaining_q:=0;
            if policy(15)(0)='1' then remaining_q:=search_iteration+to_integer(unsigned(policy(41)))-search_sp-1; end if;
            if remaining_q<0 then remaining_q:=0; elsif remaining_q>MAX_QUIESCENCE then remaining_q:=MAX_QUIESCENCE; end if;
            if node_draw(search_sp)='1' then search_result<=0; state<=SEARCH_RETURN;
            elsif repeated then
              node_repetition(search_sp)<='1'; search_result<=0; state<=SEARCH_RETURN;
            elsif policy(42)(0)='1' and node_cache_word(127)='1' and unsigned(node_cache_word(126 downto 111))=search_epoch and
                  unsigned(node_cache_word(110 downto 47))=node_hash(search_sp) then
              search_cache_hits<=search_cache_hits+1;
              node_hint(search_sp)<=node_cache_word(20 downto 5); node_hint_valid(search_sp)<='1';
              score:=to_integer(signed(node_cache_word(46 downto 31)));
              if score>27000 then score:=score-search_sp-1; elsif score< -27000 then score:=score+search_sp+1; end if;
              if unsigned(node_cache_word(30 downto 27))>=remaining_depth and unsigned(node_cache_word(26 downto 23))>=remaining_q and
                 unsigned(node_cache_word(4 downto 1))>=SEARCH_LEVELS-search_sp-1 and
                 (node_cache_word(22 downto 21)="00" or (node_cache_word(22 downto 21)="01" and score>=node_beta(search_sp)) or
                  (node_cache_word(22 downto 21)="10" and score<=node_alpha(search_sp))) then
                node_cached(search_sp)<='1'; search_result<=score; state<=SEARCH_RETURN;
              end if;
            end if;
          when NODE_READY=>
            search_building<='0'; node_remaining(search_sp)<=node_count(search_sp); state<=ADVANCE;
          when MOVE_SELECT=>
            picked:=search_pick_data; picked_index:=search_pick_index;
            if search_scan=0 or unsigned(queue_data(31 downto 16))>unsigned(picked(31 downto 16)) then
              picked:=queue_data; picked_index:=search_scan;
            end if;
            search_pick_data<=picked; search_pick_index<=picked_index;
            if search_scan+1=node_remaining(search_sp) then state<=MOVE_APPLY;
            else search_scan<=search_scan+1; end if;
          when MOVE_APPLY=>
            queue_we<='1'; queue_write_address<=search_sp*SEARCH_MOVES+search_pick_index; queue_write_data<=queue_data;
            node_remaining(search_sp)<=node_remaining(search_sp)-1;
            src<=to_integer(unsigned(search_pick_data(5 downto 0))); dst<=to_integer(unsigned(search_pick_data(11 downto 6)));
            promotion<=2;
            if unsigned(search_pick_data(14 downto 12))/=0 then promotion<=to_integer(unsigned(search_pick_data(14 downto 12))); end if;
            state<=PICK;
          when SEARCH_RECALL_WAIT=>state<=SEARCH_RECALL_COPY;
          when SEARCH_RECALL_COPY=>
            b(search_index)<=search_q;
            if search_index=63 then
              if search_returning='1' then state<=SEARCH_ACCEPT;
              else state<=ADVANCE; end if;
            else search_index<=search_index+1; state<=SEARCH_RECALL_WAIT; end if;
          when SEARCH_ACCEPT=>
            score:=node_best(search_sp);
            if active_turn=turn then
              if search_result>score then score:=search_result; node_best_move(search_sp)<=candidate_move; end if;
              if score>node_alpha(search_sp) then node_alpha(search_sp)<=score; end if;
              valid:=score>=node_beta(search_sp);
            else
              if search_result<score then score:=search_result; node_best_move(search_sp)<=candidate_move; end if;
              if score<node_beta(search_sp) then node_beta(search_sp)<=score; end if;
              valid:=score<=node_alpha(search_sp);
            end if;
            node_best(search_sp)<=score;
            if valid then
              search_cutoffs<=search_cutoffs+1; search_result<=score; state<=SEARCH_RETURN;
              if node_tactical(search_sp)='0' then
                if node_killer1(search_sp)/=candidate_move then
                  node_killer2(search_sp)<=node_killer1(search_sp); node_killer1(search_sp)<=candidate_move;
                end if;
                n:=search_iteration-search_sp; if n<1 then n:=1; end if;
                n:=to_integer(history_data)+n*n; if n>8191 then n:=8191; end if;
                history_we<='1'; history_write_address<=src*64+dst; history_write_data<=to_unsigned(n,13);
              end if;
            else
              search_returning<='0'; search_index<=0; state<=SEARCH_RECALL_WAIT;
            end if;
          when SEARCH_RETURN=>
            search_building<='0';
            if policy(42)(0)='1' and node_cached(search_sp)='0' and node_repetition(search_sp)='0' then
              cache_word:=(others=>'0'); cache_word(127):='1';
              cache_word(126 downto 111):=std_logic_vector(search_epoch);
              cache_word(110 downto 47):=std_logic_vector(node_hash(search_sp));
              score:=search_result;
              -- Store mate distance relative to this position, not its root ply.
              if score>27000 then score:=score+search_sp+1; elsif score< -27000 then score:=score-search_sp-1; end if;
              cache_word(46 downto 31):=std_logic_vector(to_signed(score,16));
              n:=search_iteration-search_sp-1; if n<0 then n:=0; end if;
              cache_word(30 downto 27):=std_logic_vector(to_unsigned(n,4));
              n:=0; if policy(15)(0)='1' then n:=search_iteration+to_integer(unsigned(policy(41)))-search_sp-1; end if;
              if n<0 then n:=0; elsif n>MAX_QUIESCENCE then n:=MAX_QUIESCENCE; end if;
              cache_word(26 downto 23):=std_logic_vector(to_unsigned(n,4));
              if search_result<=node_start_alpha(search_sp) then cache_word(22 downto 21):="10";
              elsif search_result>=node_start_beta(search_sp) then cache_word(22 downto 21):="01"; end if;
              cache_word(20 downto 5):=node_best_move(search_sp);
              cache_word(4 downto 1):=std_logic_vector(to_unsigned(SEARCH_LEVELS-search_sp-1,4));
              cache_we<='1'; cache_write_address<=to_integer(node_hash(search_sp)(CACHE_INDEX_BITS-1 downto 0)); cache_write_data<=cache_word;
              search_cache_stores<=search_cache_stores+1;
            end if;
            if search_sp=0 then state<=SEARCH_ROOT;
            else
              if node_repetition(search_sp)='1' then node_repetition(search_sp-1)<='1'; end if;
              search_sp<=search_sp-1; search_index<=0; search_returning<='1';
              src<=cursor_src(search_sp-1); dst<=cursor_dst(search_sp-1);
              promotion<=cursor_promotion(search_sp-1); promoting<=cursor_promoting(search_sp-1);
              state<=SEARCH_RECALL_WAIT;
            end if;
          when SEARCH_ROOT=>
            search_part:=search_result-base_static;
            -- Mate scores are absolute terminal outcomes, independent of the
            -- starting material advantage or the learned positional weights.
            if abs(search_result)>27000 then search_part:=search_result; search_parts<=(others=>'0'); end if;
            search_delta_score<=clip16(search_part); state<=SEARCH_SUM;
          when SEARCH_SUM=>
            -- A balanced, registered adder tree is shared by spatial-only and
            -- search modes. It prevents area sharing from building a long
            -- native-RX-to-score combinational path through serial adders.
            search_sum_a<=to_integer(signed(search_parts(95 downto 80)))+to_integer(signed(search_parts(79 downto 64)));
            search_sum_b<=to_integer(signed(search_parts(63 downto 48)))+to_integer(signed(search_parts(47 downto 32)));
            search_sum_c<=to_integer(signed(search_parts(31 downto 16)))+to_integer(signed(search_parts(15 downto 0)));
            state<=SEARCH_ADD;
          when SEARCH_ADD=>
            search_sum_a<=search_sum_a+search_delta_score; search_sum_b<=search_sum_b+search_sum_c;
            state<=SEARCH_SCORE;
          when SEARCH_SCORE=>
            total:=search_sum_a+search_sum_b;
            score:=clip16(total);
            -- synthesis translate_off
            if TRACE_SEARCH then
              report "search root "&integer'image(to_integer(unsigned(search_root_move)))&
                     " activation "&integer'image(score)&" nodes "&integer'image(to_integer(search_nodes));
            end if;
            -- synthesis translate_on
            if legal_count<256 then
              candidate_we<='1'; candidate_write_index<=candidate_bank*256+legal_count;
              candidate_write_data<=search_root_move&std_logic_vector(to_signed(score,16))&search_parts&std_logic_vector(to_signed(search_delta_score,16));
              legal_count<=legal_count+1;
            end if;
            if score>best_score then best_score<=score; best_move<=search_root_move; end if;
            src<=to_integer(unsigned(search_root_move(5 downto 0))); dst<=to_integer(unsigned(search_root_move(11 downto 6)));
            promoting<='0'; promotion<=2;
            if unsigned(search_root_move(14 downto 12))/=0 then
              promoting<='1'; promotion<=to_integer(unsigned(search_root_move(14 downto 12)));
            end if;
            search_active<='0'; b<=base; state<=ADVANCE;
          when RESTORE=>b<=base; state<=ADVANCE;
          when ADVANCE=>
            if search_active='1' and search_building='0' then
              if node_remaining(search_sp)=0 then
                score:=node_best(search_sp);
                if node_legal(search_sp)='0' then
                  score:=0;
                  if node_check(search_sp)='1' then
                    score:=28000-(search_sp+1); if active_turn=turn then score:=-score; end if;
                  end if;
                end if;
                search_result<=score; state<=SEARCH_RETURN;
              else
                search_scan<=0; search_pick_index<=0; search_pick_data<=(others=>'0'); state<=MOVE_SELECT;
              end if;
            elsif promoting='1' and promotion<5 then promotion<=promotion+1; state<=PICK;
            else
              promotion<=2;
              if dst=63 then
                dst<=0;
                if src=63 then
                  if search_active='1' then state<=NODE_READY; else state<=FINISH; end if;
                else src<=src+1; state<=PICK; end if;
              else dst<=dst+1; state<=PICK; end if;
            end if;
          when FINISH=>
            published_bank<=candidate_bank; completed_count<=legal_count; completed_move<=best_move; completed_score<=best_score;
            search_completed<=search_iteration; search_has_completed<='1'; b<=base;
            if legal_count>0 and search_iteration>=2 and search_iteration<to_integer(unsigned(policy(10))) and
               (search_limit=0 or elapsed<search_limit) then
              candidate_bank<=1-candidate_bank; search_iteration<=search_iteration+1;
              legal_count<=0; best_move<=(others=>'0'); best_score<=-32768;
              src<=0; dst<=0; promotion<=2; promoting<='0'; search_active<='0'; state<=PICK;
            else
              done<='1'; state<=IDLE; search_running<='0';
              if legal_count>0 and search_iteration<to_integer(unsigned(policy(10))) then search_timed_out<='1'; end if;
            end if;
        end case;

        -- A completed iteration has its own candidate RAM bank. Budget expiry
        -- discards the partial next iteration and publishes only that full set.
        if search_running='1' and search_has_completed='1' and search_limit/=0 and elapsed>=search_limit and state/=FINISH then
          search_active<='0'; search_building<='0'; search_running<='0'; search_timed_out<='1';
          state<=IDLE; b<=base; done<='1';
          legal_count<=completed_count; best_move<=completed_move; best_score<=completed_score;
        end if;

        if keys(2)='1' and old_keys(2)='0' and state/=LOAD_SCAN and state/=LOAD_FINISH and state/=BOOT_POLICY and state/=LOAD_POLICY and state/=LOAD_ROUTES then
          search_active<='0'; search_running<='0'; state<=IDLE; base<=initial_board; b<=initial_board; turn<='0'; rights<="1111"; ep<=64;
          wk<=4; bk<=60; done<='0'; legal_count<=0; field_valid<=(others=>'0'); field_leds<=(others=>'0'); generation<=generation+1; history_count<=0; nonpawn_count<=14;
        end if;
        if command_pending='1' then
          command_pending<='0';
          sub:=to_integer(unsigned(packet_rx(0))); len:=packet_length;
          response_done<='1'; response_status_i<=0; response_length<=1; response_kind<=1; ack<=x"00";
          mutating:=sub=1 or sub=2 or sub=3 or sub=8 or sub=9 or sub=10 or sub=11 or sub=13 or sub=17;
          duplicate:=mutating and have_token='1' and packet_token=last_token;
          if duplicate then response_status_i<=cached_status;
          else
            if mutating then last_token<=packet_token; have_token<='1'; cached_status<=0; end if;
            case sub is
              when 0=>
                if len/=1 then response_status_i<=1;
                else response_kind<=0; response_length<=32; end if;
              when 1=>
                if len/=68 or state/=IDLE or unsigned(packet_rx(65))>1 or
                   unsigned(packet_rx(66))>15 or unsigned(packet_rx(67))>64 then
                  response_status_i<=3; cached_status<=3;
                else
                  load_index<=0; load_white_kings<=0; load_black_kings<=0; load_invalid<='0';
                  load_nonpawn<=0;
                  state<=LOAD_SCAN; response_done<='0';
                end if;
              when 2=>
                if len/=1 or state/=IDLE then response_status_i<=3; cached_status<=3;
                else state<=SNAPSHOT; done<='0'; end if;
              when 3=>
                if len/=1 then response_status_i<=1; cached_status<=1;
                elsif state=BOOT_POLICY then response_status_i<=3; cached_status<=3;
                else search_active<='0'; search_running<='0'; state<=IDLE; b<=base; done<='0'; end if;
              when 4=>
                if len/=1 then response_status_i<=1;
                else response_kind<=4; response_length<=80; end if;
              when 5=>
                if len/=1 then response_status_i<=1;
                else response_kind<=5; response_length<=67; end if;
              when 6=>
                if len/=1 then response_status_i<=1;
                else response_kind<=6; response_length<=80; end if;
              when 7=>
                if len/=2 or unsigned(packet_rx(1))>15 then response_status_i<=3;
                else page<=to_integer(unsigned(packet_rx(1))); response_kind<=7; response_length<=64; end if;
              when 8=>
                if len/=81 or state/=IDLE then response_status_i<=3; cached_status<=3;
                else
                  for i in 0 to 15 loop cfg(i)<=packet_rx(i+1); end loop;
                  route_index<=0; state<=LOAD_ROUTES; response_done<='0'; done<='0';
                end if;
              when 9=>
                if len/=5 then response_status_i<=1; cached_status<=1;
                else
                  seed32:=unsigned(std_logic_vector'(packet_rx(1)&packet_rx(2)&packet_rx(3)&packet_rx(4)));
                  if seed32=0 then seed32:=x"D0E2C35F"; end if;
                  rng<=seed32;
                end if;
              when 10=>
                if len/=1 then response_status_i<=1; cached_status<=1;
                elsif policy_initialized='0' then response_status_i<=3; cached_status<=3;
                else
                  search_active<='0'; search_running<='0'; state<=IDLE; base<=initial_board; b<=initial_board; turn<='0'; rights<="1111"; ep<=64;
                  wk<=4; bk<=60; done<='0'; legal_count<=0; field_valid<=(others=>'0'); field_leds<=(others=>'0'); generation<=generation+1; history_count<=0; nonpawn_count<=14;
                end if;
              when 11=>
                -- Commit only the exact hardware-selected move, with generation
                -- guard. This cannot bypass the legality filter or replay a ply.
                if len/=7 or state/=IDLE or done='0' or legal_count=0 or
                   unsigned(std_logic_vector'(packet_rx(1)&packet_rx(2)&packet_rx(3)&packet_rx(4)))/=generation or
                   std_logic_vector'(packet_rx(5)&packet_rx(6))/=best_move then
                  response_status_i<=3; cached_status<=3;
                else
                  src<=to_integer(unsigned(best_move(5 downto 0)));
                  dst<=to_integer(unsigned(best_move(11 downto 6)));
                  n:=to_integer(unsigned(best_move(14 downto 12)));
                  promoting<='0'; if n>=2 and n<=5 then promotion<=n; promoting<='1'; end if;
                  k:=to_integer(unsigned(best_move(5 downto 0)));
                  x:=to_integer(unsigned(best_move(11 downto 6)));
                  moving<=base(k); captured<=base(x); en_passant<='0'; castling<='0';
                  if kind(base(k))=1 and x=ep and kind(base(x))=0 then en_passant<='1'; end if;
                  if kind(base(k))=6 and abs(x-k)=2 then castling<='1'; end if;
                  state<=COMMIT_MOVE;
                end if;
              when 12=>
                if len/=2 or unsigned(packet_rx(1))>1 or state/=IDLE then response_status_i<=3;
                else policy_page<=to_integer(unsigned(packet_rx(1))); response_kind<=12; response_length<=64; end if;
              when 13=>
                if len/=66 or state/=IDLE or unsigned(packet_rx(1))>1 then response_status_i<=3; cached_status<=3;
                elsif packet_rx(1)=x"00" and (unsigned(packet_rx(12))=1 or unsigned(packet_rx(12))>MAX_SEARCH_DEPTH or unsigned(packet_rx(14))>32 or unsigned(packet_rx(15))>32 or unsigned(packet_rx(17))>1 or
                      unsigned(packet_rx(42))>60 or unsigned(packet_rx(43))>MAX_QUIESCENCE or unsigned(packet_rx(44))>1) then
                  response_status_i<=3; cached_status<=3;
                else
                  policy_page<=to_integer(unsigned(packet_rx(1)(0 downto 0))); policy_index<=0;
                  state<=LOAD_POLICY; response_done<='0'; done<='0';
                end if;
              when 18=>
                if len=1 then response_kind<=18; response_length<=20;
                else response_status_i<=1; end if;
              when 14=>
                if len/=2 or unsigned(packet_rx(1))>63 then response_status_i<=3;
                else page<=to_integer(unsigned(packet_rx(1))); response_kind<=14; response_length<=72; end if;
              when 17=>
                if len<2 or state/=IDLE or unsigned(packet_rx(1))>8 then response_status_i<=3; cached_status<=3;
                elsif len/=2+to_integer(unsigned(packet_rx(1)))*2 then response_status_i<=1; cached_status<=1;
                else
                  history_count<=to_integer(unsigned(packet_rx(1)));
                  for i in 0 to 7 loop history(i)<=packet_rx(2+i*2)&packet_rx(3+i*2); end loop;
                  done<='0';
                end if;
              when others=>response_status_i<=2;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;

