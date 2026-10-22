package require ::quartus::project
package require ::quartus::sta
project_open de10_chess
create_timing_netlist
read_sdc
update_timing_netlist
set failed 0
foreach_in_collection oc [get_available_operating_conditions] {
    set_operating_conditions $oc
    update_timing_netlist
    foreach check {setup hold recovery removal} {
        set paths [get_timing_paths -$check -npaths 1]
        foreach_in_collection path $paths {
            set slack [get_path_info -slack $path]
            puts "[get_operating_conditions_info -display_name $oc] $check slack: $slack ns"
            if {$slack < 0} { set failed 1 }
        }
    }
}
if {[get_collection_size [get_clocks board_clock]] != 1} { set failed 1 }
delete_timing_netlist
project_close
if {$failed} { error "Timing requirements were not met" }
