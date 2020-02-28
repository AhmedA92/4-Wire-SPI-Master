library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity spi_master_module is generic(f_cdiv : integer := 1 );                       --f_sclk = f_sys/ (2*f_cdiv);
                            Port (clk, reset: in std_logic;
                                  addr      : in std_logic_vector(7 downto 0);     --select slave / active low.
                                  data_tx   : in std_logic_vector(7 downto 0);     --data to be sent through the module interface.
                                  data_rx   : out std_logic_vector(7 downto 0);    --data received from the module interface.
                                  CPOL,CPHA : in std_logic;
                                  en        : in std_logic;
                                  busy      : out std_logic_vector (1 downto 0);   --LSB -> busy by TX / MSB -> RX data available.
                                  --device interface
                                  sclk      : out std_logic;
                                  s_sel     : out std_logic_vector(7 downto 0);    --Normally high / active low for selection.
                                  mosi      : out std_logic;
                                  miso      : in std_logic);
end spi_master_module;

architecture Behavioral of spi_master_module is
--STATES
constant start : std_logic_vector (2 downto 0) := "000";
constant mode_one : std_logic_vector (2 downto 0):= "001";      --CPHA = 0
constant mode_two : std_logic_vector (2 downto 0):= "010";      --CPHA = 1
constant mode_inter : std_logic_vector (2 downto 0):= "011";

signal state : std_logic_vector (2 downto 0);
--BUFFERS TO SAVE INPUT
signal sclk_prev, sclk_curr : std_logic;
signal tx_buffer, rx_buffer, sel_buffer : std_logic_vector(7 downto 0); 
--TIMERS TO KEEP TRACK OF "SCLK" AND DATA COUNTER. 
signal clk_timer,data_timer : integer := 0;
--SIGNALS RELATED TO INTERMEDIATE STATE.
signal mode_buffer : std_logic_vector (2 downto 0) := start;
signal wait_stable : integer := 0;
begin

    process(clk,reset) begin
        if reset = '1' then
            state <= start;
            data_rx <= "00000000";
            busy <= "00";
            s_sel <= "11111111";
        else    
            if rising_edge(clk)then
                sclk_prev <= sclk_curr;
                case state is
                    ----------------------------------------------------------------------
                    --START PHASE : DETECTION OF ENABLE & SETTING UP MODES.
                    ----------------------------------------------------------------------
                    when start =>
                        wait_stable <= 0; 
                        mosi <= 'Z'; 
                        s_sel <= "11111111";   
                        if en = '1' then
                            if CPHA = '0'  then
                                state <= mode_one;
                            elsif CPHA = '1' then
                                state <= mode_two;     
                            end if;
                            sel_buffer <= addr;
                            tx_buffer <= data_tx;  
                        else    
                            state <= start;  
                        end if;
                    ----------------------------------------------------------------------
                    --MODE ONE : CPHA = 0 / DATA STRATS AT SLAVE SELECTION.
                    ----------------------------------------------------------------------    
                    when mode_one => 
                        if wait_stable < 3 then 
                            mode_buffer <= mode_one;
                            state <= mode_inter; 
                        else     
                            --issue busy signal.
                            busy <= "01";
                            --assign address.
                            s_sel <= sel_buffer;
                            if data_timer = 0 then
                                mosi <= tx_buffer(0);
                                data_timer <= 1;
                            end if;
                            if sclk_prev /= sclk_curr then
                                if CPOL = '0' then  --rising edge
                                    if sclk_prev = '0' and sclk_curr <= '1' then    --rising edge
                                        if data_timer < 8 then
                                            mosi <= tx_buffer(data_timer);
                                            data_timer <= data_timer + 1;
                                            state <= mode_one;
                                            rx_buffer <= miso & rx_buffer(7 downto 1);
                                        else                
                                            data_timer <= 0;
                                            state <= start;       
                                        end if;
                                    end if;
                                else
                                    if sclk_prev = '1' and sclk_curr <= '0' then    --falling edge  
                                        if data_timer < 8 then
                                            mosi <= tx_buffer(data_timer);
                                            data_timer <= data_timer + 1;
                                            state <= mode_one;
                                            rx_buffer <= miso & rx_buffer(7 downto 1);
                                        else                
                                            data_timer <= 0;
                                            state <= start;  
                                            busy <= "10";     
                                        end if;
                                    end if;      
                                end if;    
                            end if;           
                        end if;
                    ----------------------------------------------------------------------
                    --MODE TWO : CPHA = 1 / DATA STARTS AT RISING/FALLING EDGE OF "SCLK".
                    ----------------------------------------------------------------------
                    when mode_two =>
                        if wait_stable < 3 then
                            mode_buffer <= mode_two;
                            state <= mode_inter;
                        else 
                            --issue busy signal.
                            busy <= "01";
                            --assign address.
                            s_sel <= sel_buffer;
                            if sclk_prev /= sclk_curr then
                                --check CPOL for rising/faling edge detection.
                                if CPOL = '0' then  --rising edge
                                    if sclk_prev = '1' and sclk_curr <= '0' then    --rising edge
                                        if data_timer < 8 then
                                            mosi <= tx_buffer(data_timer);
                                            data_timer <= data_timer + 1;
                                            state <= mode_two;
                                            rx_buffer <= miso & rx_buffer(7 downto 1);
                                        else
                                            data_timer <= 0;
                                            state <= start;       
                                        end if;
                                    end if;
                                else                --falling edge
                                    if sclk_prev = '0' and sclk_curr <= '1' then    --falling edge
                                        if data_timer < 8 then
                                            mosi <= tx_buffer(data_timer);
                                            data_timer <= data_timer + 1;
                                            state <= mode_two;
                                            rx_buffer <= miso & rx_buffer(7 downto 1);
                                        else
                                            data_timer <= 0;
                                            state <= start; 
                                            busy <= "10";      
                                        end if;
                                    end if;
                                end if;
                            end if;
                        end if;
                    -----------------------------------------------------------------------------------------------------------
                    --MODE THREE(INTERMEDIATE): THE JOB OF THIS PHASE IS TO MAKE SURE THE "SCLK" IS STABLE ENOUGH TO SEND DATA.
                    -----------------------------------------------------------------------------------------------------------
                    when mode_inter =>
                        if sclk_prev /= sclk_curr then
                            if wait_stable < 3 then
                               wait_stable <= wait_stable +1;
                               
                            else
                                state <= mode_buffer;  
                                --wait_stable <= 0;  
                            end if;
                        end if;
                    ----------------------------------------------------------------------------------------------------------                   
                    when others => state <= start;
                end case;
            end if;
        end if;    
    end process;
    
    ----------------------------------------------------------------------
    -- SCLK GENERATION PROCESS.
    ----------------------------------------------------------------------
    S_CLK_GEN: process(clk, reset)begin
        if rising_edge(clk) then
            if reset = '1' or state = start then
                if CPOL = '0' then
                    sclk_curr <= '0';
                else
                    sclk_curr <= '1';
                end if;
            else
                if clk_timer < f_cdiv-1 then
                    clk_timer <= clk_timer  + 1;
                else 
                    sclk_curr <= not(sclk_curr);
                    clk_timer <= 0;        
                end if;    
            end if;
        end if;    
    end process;

    data_rx <= rx_buffer;
    sclk <= sclk_curr;
end Behavioral;
