return function(driver_state)
    local env = "D\x00\x64w\x04\x00D\x00\x40w\x08\x00D\x00\x28w\x60\x00D\x00\x08w\x80\x00!"
    driver_state.effect_data[1] = env
    driver_state.track_states[1].effect_states.vol_adsr:set_data(driver_state.effect_data[1])
    driver_state.track_states[1].reader:set_data(
        "o\x05cw\x50\x00dw\x50\x00cw\x70\x00!"
    )
    driver_state.effect_data[2] = env
    driver_state.track_states[2].effect_states.vol_adsr:set_data(driver_state.effect_data[2])
    driver_state.track_states[2].reader:set_data(
        "o\x04gw\x78\x00fw\x28\x00ew\x70\x00!"
    )
    driver_state.track_states[3].reader:set_data(
        "o\x03ew\x50\x00o\x02gw\x50\x00o\x03cw\x70\x00!"
    )
end
