--[[
MIT License

Copyright (c) 2019 hngsm

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

print "HTTP/1.1 200 OK\r"
print "Content-Type: text/html\r\n\r"
print "FlashAir PWM music sequencer"

-- player stops after this duration elapsed.
local TIMELIMIT = 10 --43200 -- seconds

local load_song = loadfile('pwm/songs/test1.lua')()

fa.sharedmemory("write", 0, 1, "1")

local function get_shmem_status()
    return fa.sharedmemory("read", 0, 1)
end

local function set_shmem_status(s)
    return fa.sharedmemory("write", 0, 1, s)
end

local function stop_cond()
    local m = get_shmem_status()
    return m == "0" or m == "2"
end

local function wait_start_cond()
    while true do
        local m = get_shmem_status()
        if m == "1" or m == "2" then
            return
        end
        sleep(100)
    end
end

local function kill_cond()
    local m = get_shmem_status()
    return m == "2"
end

-- D0, D1 --> AND --> square ch 1
-- D2, D3 --> AND --> square ch 2
-- CMD -------------> square ch 3 or PCM

local VOLFREQ = 400 * 1000
local INAUDIBLE_FREQ = VOLFREQ * 100

local CH1W = 1 -- square ch 1 wave
local CH1V = 2 -- square ch 1 volume (VOLFREQ Hz)
local CH2W = 3 -- square ch 2 wave
local CH2V = 4 -- square ch 2 volume (VOLFREQ Hz)
local CH3W = 0 -- square ch 3 or PCM

-- for Linux
local function dummy_fa_setup()
    pc_print = function() end
    local frame = 0
    frame_inc = function()
        frame = frame + 1
    end
    if fa == nil then
        -- Invoked from linux's lua
        local tmsec = 0
        os.clock = function()
            tmsec = tmsec + 1
            return tmsec / 1000
        end
        fa = {}
        fa.pwm = function(a,b,c,d)
            print(a,b,c,d, frame, tmsec)
        end
        fa.sharedmemory = function(a,b,c,d)
            return "1"
        end
        pc_print = print
    end
end

local function allinit()
    for i=0,4 do
        a, b = fa.pwm("init", i, 1)
    end
end

local function silence()
    for i=0,4 do
        fa.pwm("init", i, 1)
    end
    fa.pwm("duty", CH1V, VOLFREQ, 0)
    fa.pwm("start", CH1V)
    fa.pwm("init", CH2V, 1)
    fa.pwm("duty", CH2V, VOLFREQ, 0)
    fa.pwm("start", CH2V)

    fa.pwm("init", CH1W, 1)
    fa.pwm("duty", CH1W, INAUDIBLE_FREQ, 50.0)
    fa.pwm("start", CH1W)

    fa.pwm("init", CH2W, 1)
    fa.pwm("duty", CH2W, INAUDIBLE_FREQ, 50.0)
    fa.pwm("start", CH2W)

    fa.pwm("init", CH3W, 1)
    fa.pwm("duty", CH3W, INAUDIBLE_FREQ, 50.0)
    fa.pwm("start", CH3W)
end

local function allstop()
    for i=0,4 do
        a, b = fa.pwm("stop", i)
    end
end

-- Sequence byte stream reader
-- Usage:
-- reader = Reader:new(data)
-- reader:fetch(1)
local Reader = {
    new = function(klass, data)
        local self = setmetatable({}, {__index = klass})
        self.data = data
        self.pos = 1
        self.loop_pos = 1
        return self
    end,

    peek = function(self, num)
        local c = string.sub(self.data, self.pos, self.pos + num - 1)
        return c
    end,

    fetch = function(self, num)
        local cmd = self:peek(num)
        self.pos = self.pos + num
        if self.pos > string.len(self.data) then
            self.pos = self.loop_pos
        end
        return cmd
    end,

    fetch_uint8 = function(self)
        local amount = self:fetch(1)
        return string.byte(amount)
    end,

    fetch_uint16 = function(self)
        local amount = self:fetch(2)
        local lo, hi = string.byte(amount, 1, 2)
        return hi * 256 + lo
    end,

    set_data = function(self, data)
        self.data = data
    end,

    set_loop_pos_to_current = function(self)
        self.loop_pos = self.pos
    end,

    reset = function(self)
        self.pos = 1
        self.loop_pos = 1
    end,
}

local Adsr = {
    new = function(klass, data)
        local self = setmetatable({}, {__index = klass})
        self.reader = Reader:new("!")
        self.wait_counter = 0
        self.rate = 0
        self.target = 0
        self.out = 100
        self.active = false
        return self
    end,

    set_data = function(self, data)
        self.reader:set_data(data)
        self.reader:reset()
    end,

    process_keyon = function(self)
        self.active = true
        self.reader:reset()
        self.wait_counter = 0
    end,

    run_frame = function(self)
        if not self.active then
            return
        end
        while true do
            if self.wait_counter ~= 0 then
                break
            end
            if not self.active then
                break
            end
            local cmd = self.reader:fetch(1)
            if cmd == "D" then
                -- direct
                local operand = self.reader:fetch_uint16()
                operand = operand / 256.0
                self.out = operand
                --track_state.volume_dirty = true
            elseif cmd == "L" then
                self.reader:set_loop_pos_to_current()
            elseif cmd == "w" then
                local operand = self.reader:fetch_uint16()
                self.wait_counter = operand
            elseif cmd == "!" then
                self.active = false
            else
                print("unknown cmd! " .. cmd .." \n")
            end
        end
        if self.active then
            self.wait_counter = self.wait_counter - 1
        end
    end,

    get_output = function(self)
        return self.out
    end,
}

local function player()
    -- octave 8, c c# d ...
    local freq_table = {4186.009, 4434.922, 4698.636, 4978.032, 5274.041, 5587.652, 5919.911, 6271.927, 6644.875, 7040.000, 7458.620, 7902.133}
    local function get_freq(note, oct)
        local note2pos = {
            c = 0, ["c#"] = 1, d = 2, ["d#"] = 3, e = 4, f = 5, ["f#"] = 6, g = 7, ["g#"] = 8, a = 9, ["a#"] = 10, b = 11
        }
        local powof2 = {
            1, 2, 4, 8, 16, 32, 64, 128, 256
        }
        local o8freq = freq_table[note2pos[note] + 1]
        local divisor = powof2[8 - oct + 1]
        return o8freq / divisor
    end
    local function test_get_freq()
        for _, oct in ipairs{0, 1, 2, 3, 4, 5, 6, 7, 8} do
            for _, n in ipairs{"c","c#","d","d#","e","f","f#","g","g#","a","a#","b"} do
                print(n, oct, get_freq(n, oct))
            end
        end
    end
    local function init_register()
        for i=0,4 do
            fa.pwm("init", i, 1)
        end
        fa.pwm("duty", CH1V, VOLFREQ, 0)
        fa.pwm("start", CH1V)
        fa.pwm("init", CH2V, 1)
        fa.pwm("duty", CH2V, VOLFREQ, 0)
        fa.pwm("start", CH2V)

        fa.pwm("init", CH1W, 1)
        fa.pwm("duty", CH1W, INAUDIBLE_FREQ, 50.0)
        fa.pwm("start", CH1W)

        fa.pwm("init", CH2W, 1)
        fa.pwm("duty", CH2W, INAUDIBLE_FREQ, 50.0)
        fa.pwm("start", CH2W)

        fa.pwm("init", CH3W, 1)
        fa.pwm("duty", CH3W, INAUDIBLE_FREQ, 50.0)
        fa.pwm("start", CH3W)
    end
    local driver_state = {}
    local function init_driver_state()
        driver_state.chan_states = {{}, {}, {}}
        driver_state.track_states = {{}, {}, {}}
        driver_state.data_end = false
        driver_state.effect_data = {}
        for chnum, chan_state in ipairs(driver_state.chan_states) do
            chan_state.chan = chnum
        end
        for chnum, track_state in ipairs(driver_state.track_states) do
            track_state.chan = chnum
            track_state.reader = Reader:new("Lw\x20\x00")
            track_state.wait_counter = 0
            track_state.note = "c"
            track_state.octave = 0
            track_state.keyon = false -- event
            track_state.keyoff = false -- event
            track_state.keypressed = false -- state
            track_state.effect_states = {}
            track_state.effect_states.vol_adsr = Adsr:new("!")
            track_state.freq = INAUDIBLE_FREQ
            track_state.freq_dirty = false
            track_state.volume = 0
            track_state.volume_dirty = false
            track_state.duty = 50
            track_state.duty_dirty = false
        end
    end
    local function process_note(trnum, track_state, note)
        local freq = get_freq(note, track_state.octave)
        track_state.note = note
        track_state.freq = freq
        track_state.freq_dirty = true
        track_state.keyon = true
        track_state.keypressed = true
    end
    local cmd_funcs = {
        -- Loop
        -- L
        -- Set loop point to next of this command.
        ["L"] =
            function(trnum, track_state)
                track_state.reader:set_loop_pos_to_current()
            end,
        -- Wait
        -- w\xXX\xYY
        -- wait (0xYY << 8)| 0xXX frames (little endian.)
        ["w"] =
            function(trnum, track_state)
                track_state.wait_counter = track_state.reader:fetch_uint16()
            end,
        -- Volume
        -- v\xXX
        -- Set volume to 0xXX
        ["v"] =
            function(trnum, track_state)
                track_state.volume = track_state.reader:fetch_uint8()
                track_state.volume_dirty = true
            end,
        ["o"] =
            function(trnum, track_state)
                track_state.octave = track_state.reader:fetch_uint8()
            end,
        -- freq (temporary!!)
        -- F\xXX\xYY
        -- Set freq
        ["F"] =
            function(trnum, track_state)
                track_state.freq = track_state.reader:fetch_uint16()
                track_state.freq_dirty = true
                track_state.keyon = true
                track_state.keypressed = true
            end,
        -- end (temporary!!)
        ["!"] =
            function(trnum, track_state)
                driver_state.data_end = true
            end,
    }
    local function sequencer()
        for trnum, track_state in ipairs(driver_state.track_states) do
            while true do
                if track_state.wait_counter ~= 0 then
                    break
                end
                if driver_state.data_end then
                    return
                end
                local cmd = track_state.reader:fetch(1)
                --pc_print("cmd", cmd)
                if cmd_funcs[cmd] then
                    cmd_funcs[cmd](trnum, track_state)
                else
                    local notenum = string.find("c!d!ef!g!a!b",cmd)
                    if notenum then
                        local note = cmd
                        local acc = track_state.reader:peek(1)
                        if acc == "#" then
                            track_state.reader:fetch(1)
                            note = note .. acc
                        end
                        process_note(trnum, track_state, note)
                    end
                end
            end
            track_state.wait_counter = track_state.wait_counter - 1
        end
    end
    local function process_keyevent(track_state)
        if track_state.keyon then
            track_state.effect_states.vol_adsr:process_keyon()
        end
    end
    local function process_timbre()
        for trnum, track_state in ipairs(driver_state.track_states) do
            process_keyevent(track_state)
        end
        for trnum, track_state in ipairs(driver_state.track_states) do
            -- Volume ADSR
            track_state.effect_states.vol_adsr:run_frame()
        end
        for trnum, track_state in ipairs(driver_state.track_states) do
            local adsr_out = track_state.effect_states.vol_adsr:get_output()
            local prev_volume = track_state.volume
            track_state.volume = adsr_out
            if prev_volume ~= track_state.volume then
                track_state.volume_dirty = true
            end
        end
    end
    local function clear_keyon()
        for trnum, track_state in ipairs(driver_state.track_states) do
            track_state.keyon = false
        end
    end
    local function write_register()
        for trnum, track_state in ipairs(driver_state.track_states) do
            if track_state.freq_dirty or track_state.duty_dirty then
                if trnum == 1 then
                    fa.pwm("duty", CH1W, track_state.freq, track_state.duty)
                elseif trnum == 2 then
                    fa.pwm("duty", CH2W, track_state.freq, track_state.duty)
                elseif trnum == 3 then
                    fa.pwm("duty", CH3W, track_state.freq, track_state.duty)
                end
            end
            track_state.freq_dirty = false
            track_state.duty_dirty = false
            if track_state.volume_dirty then
                if trnum == 1 then
                    fa.pwm("duty", CH1V, VOLFREQ, track_state.volume)
                elseif trnum == 2 then
                    fa.pwm("duty", CH2V, VOLFREQ, track_state.volume)
                else
                    -- do nothing on trnum 3
                end
            end
            track_state.volume_dirty = false
        end
    end
    local function driverloop()
        local finished = false
        local now
        local before = os.clock() * 1000
        local FRAME_PERIOD = 16
        local timelimit = before + TIMELIMIT * 1000
        local temp = 1
        while not driver_state.data_end do
            repeat
                now = os.clock() * 1000
                --print("waiting")
                if now > timelimit then
                    print("over timelimit")
                    return
                end
                if now - before < (FRAME_PERIOD-5) then
                    sleep(1)
                    if stop_cond() then
                        print("stop condition")
                        return
                    end
                end
            until now - before >= FRAME_PERIOD
            before = before + FRAME_PERIOD
            pc_print(".")
            sequencer()
            process_timbre()
            clear_keyon()
            write_register()
            frame_inc()
        end
    end
    local function main()
        init_driver_state()
        load_song(driver_state)
        init_register()
        driverloop()
    end
    print(pcall(main))
end


dummy_fa_setup()
--while true
do
    silence()
    wait_start_cond()
    if kill_cond() then
        return
    end
    sleep(250)
    player()
    allstop()
end
