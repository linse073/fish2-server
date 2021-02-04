local skynet_m = require "skynet_m"
local timer = require "timer"
local share = require "share"
local loop_time = require "loop_data"
local util = require "util"

local string = string
local pairs = pairs
local ipairs = ipairs
local table = table
local math = math

local game_mode = skynet_m.getenv("game_mode")

local MAX_USER = 4
local ACTIVITY_TIMEOUT = 60 * 100 * 30
local SPLINE_INTERVAL = 25
local FROZEN_TIME = 15

local message
local s_to_c
local c_to_s_i
local error_code
local fish_data
local spline_data
local event_data
local define
local event_type
local fish_type
local skill_status
local camera_spline
local matrix_data
local skill_data
local item_type

local agent_mgr
local game_message
local event_function
local skill_function

skynet_m.init(function()
    agent_mgr = skynet_m.queryservice("agent_mgr")
    if game_mode == "fake_game" then
        game_message = skynet_m.queryservice("fake_message")
    else
        game_message = skynet_m.queryservice("game_message")
    end
    message = share.message
    s_to_c = message.s_to_c
    c_to_s_i = message.c_to_s_i
    error_code = message.error_code
    fish_data = share.fish_data
    spline_data = share.spline_data
    event_data = share.event_data
    define = share.define
    event_type = define.event_type
    fish_type = define.fish_type
    skill_status = define.skill_status
    item_type = define.item_type
    camera_spline = share.camera_spline
    matrix_data = share.matrix_data
    skill_data = share.skill_data
    event_function = {
        [event_type.active_scene_spline] = function(self, info)
            self._spline[info.spline_id] = info
        end,
        [event_type.deactive_scene_spline] = function(self, info)
            self._spline[info.spline_id] = nil
        end,
        [event_type.active_camera_spline] = function(self, info)
            self._use_follow_spline = true
        end,
        [event_type.deactive_camera_spline] = function(self, info)
            self._use_follow_spline = false
        end,
        [event_type.active_fish] = function(self, info)
            local data = fish_data[info.fish_id]
            if info.spline_id > 0 then
                local ready = self._fish_pool[data.type].ready
                ready[#ready+1] = {info, data}
            else
                local pool = self._fish_pool[data.type].pool
                pool[#pool+1] = {info, data}
            end
        end,
        [event_type.deactive_fish] = function(self, info)
            local data = fish_data[info.fish_id]
            local pool = self._fish_pool[data.type].pool
            for i = #pool, 1, -1 do
                if pool[i][1].fish_id == info.fish_id then
                    table.remove(pool, i)
                end
            end
        end,
        [event_type.fight_boss] = function(self, info)
            local event = self._event
            event.info = info
            event.time = self._game_time - info.time
            if info.fish_id > 0 then
                local fdata = fish_data[info.fish_id]
                local sdata = skill_data[info.fish_id]
                local data = {
                    fish_data = fdata,
                    skill_data = sdata,
                }
                if sdata then
                    local rand_skill = {}
                    for i = 1, #sdata.skill do
                        rand_skill[#rand_skill+1] = i
                    end
                    util.shuffle(rand_skill)
                    data.rand_skill = rand_skill
                    data.skill_index = 0
                    data.skill_time = sdata.born_time - event.time
                    data.skill_status = skill_status.ready
                end
                for k, v in pairs(self._fish) do
                    if v.fish_id == info.fish_id then
                        data.fish = v
                        break
                    end
                end
                if not data.fish then
                    local ready = self._fish_pool[fdata.type].ready
                    local find = false
                    for k, v in ipairs(ready) do
                        if v[1].fish_id == info.fish_id then
                            find = true
                            break
                        end
                    end
                    if fdata.type == fish_type.boss_fish then
                        local pool = self._fish_pool[fdata.type].pool
                        for k, v in ipairs(pool) do
                            if v[1].fish_id == info.fish_id then
                                find = true
                                break
                            end
                        end
                    end
                    if not find then
                        skynet_m.log(string.format("Can't find target fish[%d] of event[%d].", info.fish_id, info.id))
                    end
                end
                event.data = data
            end
            local msg = string.pack(">I2>I4>f", s_to_c.trigger_event, info.id, info.duration - event.time)
            self:broadcast(msg)
        end,
        [event_type.max_small_fish] = function(self, info)
            self._fish_pool[fish_type.small_fish].max_count = info.num
        end,
        [event_type.max_big_fish] = function(self, info)
            self._fish_pool[fish_type.big_fish].max_count = info.num
        end,
    }
    skill_function = {
        [skill_status.ready] = function(self, data, etime, new_fish)
            data.skill_time = data.skill_time - etime
            if data.skill_time <= 0 then
                data.skill_index = data.skill_index + 1
                local fish_skill = data.rand_skill[data.skill_index]
                skynet_m.log(string.format("cast skill %d", fish_skill))
                -- util.dump(data)
                data.skill_info = data.skill_data.skill[fish_skill]
                data.skill_fish = {}
                data.fish_index = 1
                data.hit_count = 0
                data.skill_time = -data.skill_time
                data.skill_status = skill_status.cast
                if data.fish then
                    local msg = string.pack(">I2>I4>I2", s_to_c.cast_skill, data.fish.id, fish_skill)
                    self:broadcast(msg)
                end
                local fish_pool = data.skill_info.fish
                while data.fish_index <= #fish_pool do
                    local fish_info = fish_pool[data.fish_index]
                    if data.skill_time < fish_info.time then
                        break
                    end
                    self:new_skill_fish(fish_info, data.skill_time - fish_info.time, data.skill_fish, new_fish)
                    data.fish_index = data.fish_index + 1
                end
            end
        end,
        [skill_status.cast] = function(self, data, etime, new_fish)
            data.skill_time = data.skill_time + etime
            -- skynet_m.log(string.format("skill time %f", data.skill_time))
            if data.skill_time >= data.skill_info.duration then
                local del_count, del_msg = 0, ""
                for k, v in pairs(data.skill_fish) do
                    self:delete_fish(v, false)
                    del_count = del_count + 1
                    del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
                end
                if data.fish then
                    local msg = string.pack(">I2>I4B", s_to_c.end_skill, data.fish.id, 0)
                    self:broadcast(msg)
                end
                if data.skill_index < #data.rand_skill then
                    data.skill_time = data.skill_data.interval - (data.skill_time - data.skill_info.duration)
                    data.skill_status = skill_status.ready
                else
                    data.skill_time = 0
                    data.skill_status = skill_status.done
                    if data.fish then
                        self:delete_fish(data.fish, false)
                        del_count = del_count + 1
                        del_msg = del_msg .. string.pack(">I4>I4", data.fish.id, data.fish.fish_id)
                        data.fish = nil
                    end
                end
                skynet_m.log(string.format("End skill %d", data.rand_skill[data.skill_index]))
                if del_count > 0 then
                    -- TODO: send delete fish message to game server
                    del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
                    self:broadcast(del_msg)
                end
                data.skill_fish = nil
                data.skill_info = nil
                data.fish_index = nil
                data.hit_count = nil
            else
                local fish_pool = data.skill_info.fish
                while data.fish_index <= #fish_pool do
                    local fish_info = fish_pool[data.fish_index]
                    if data.skill_time < fish_info.time then
                        break
                    end
                    self:new_skill_fish(fish_info, data.skill_time - fish_info.time, data.skill_fish, new_fish)
                    data.fish_index = data.fish_index + 1
                end
            end
        end,
        [skill_status.done] = function(self, data, etime, new_fish)
        end,
    }
end)

local timestep = {}

function timestep:init(room_id)
    self._room_id = room_id
    self._user = {}
    self._pos = {}
    self._count = 0
    self._ready_count = 0
    self:clear()
    self._check_func = function()
        self:checkActivity()
        timer.done_routine("timestep_check")
    end
    self._update_func = function()
        self:update()
        timer.done_routine("timestep_update")
    end
end

function timestep:join(user_id, free_pos, agent)
    self:kick(user_id)
    if self._count >= MAX_USER then
        skynet_m.log("Max user.")
        return false
    end
    free_pos = free_pos + 1
    if free_pos <= 0 or free_pos > MAX_USER then
        skynet_m.log(string.format("Illegal pos %d.", free_pos))
        return false
    end
    local now = skynet_m.now()
    local info = {
        user_id = user_id,
        agent = agent,
        ready = false,
        pos = free_pos,
        status_time = now,
        bullet = {},
    }
    self._user[user_id] = info
    self._pos[free_pos] = info
    self._count = self._count + 1
    -- NOTICE: game server notify user leave
    -- timer.add_routine("timestep_check", self._check_func, 100)
    return true
end

function timestep:join_01(user_id, agent)
    self:kick(user_id)
    if self._count >= MAX_USER then
        skynet_m.log("Max user.")
        return false
    end
    local free_pos = 0
    for i = 1, MAX_USER do
        if not self._pos[i] then
            free_pos = i
            break
        end
    end
    if free_pos == 0 then
        skynet_m.log("No free pos.")
        return false
    end
    local now = skynet_m.now()
    local info = {
        user_id = user_id,
        agent = agent,
        ready = false,
        pos = free_pos,
        status_time = now,
        bullet = {},
    }
    self._user[user_id] = info
    self._pos[free_pos] = info
    self._count = self._count + 1
    timer.add_routine("timestep_check", self._check_func, 100)
    return true
end

function timestep:checkActivity()
    local now = skynet_m.now()
    for k, v in pairs(self._user) do
        if now - v.status_time >= ACTIVITY_TIMEOUT then
            skynet_m.send_lua(agent_mgr, "quit", k, error_code.low_activity)
        end
    end
end

function timestep:clear()
    self._last_time = 0
    self._bullet_id = 0
    self._bullet = {}
    self._game_time = 0
    self._fish_id = 1000
    self._group_id = 0
    self._fish = {}
    self._spline = {}
    self._spline_cd = {}
    self._fish_pool = {
        [fish_type.small_fish] = {
            pool = {},
            count = 0,
            max_count = 30,
            time = 0,
            interval = 4,
            rand_min = 5,
            rand_max = 15,
            ready = {},
        },
        [fish_type.big_fish] = {
            pool = {},
            count = 0,
            max_count = 15,
            time = 0,
            interval = 5,
            rand_min = 3,
            rand_max = 5,
            ready = {},
        },
        [fish_type.boss_fish] = {
            pool = {},
            ready = {},
        },
    }
    self._event = {
        index = 1,
        time = 0,
        info = nil,
    }
    self._item = {}
    self._use_follow_spline = true
    self._spline_time = 0
    self._item_id = 0
    timer.del_all()
end

function timestep:loop()
    self._event.index = 1
    local small_pool = self._fish_pool[fish_type.small_fish]
    small_pool.pool = {}
    small_pool.max_count = 50
    local big_pool = self._fish_pool[fish_type.big_fish]
    big_pool.pool = {}
    big_pool.max_count = 30
    self._spline = {}
    self._spline_cd = {}
    self._use_follow_spline = true
end

function timestep:start()
    self._last_time = skynet_m.now()
    timer.add_routine("timestep_update", self._update_func, 10)
    math.randomseed(self._last_time)
    self:update()
end

function timestep:new_skill_fish(info, time, skill_fish, new_fish)
    local data = fish_data[info.fish_id]
    self._group_id = self._group_id + 1
    local spline_id = info.spline_id
    if spline_id > 0 then
        self._spline_cd[spline_id] = 10
    end
    local life_time = data.life_time
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, info.num do
        self._fish_id = self._fish_id + 1
        local new_info = {
            id = self._fish_id,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = self._group_id,
            speed = info.speed,
            life_time = life_time,
            time = time,
            data = data,
            matrix_id = matrix_id,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[self._fish_id] = new_info
        if info.in_count then
            skill_fish[self._fish_id] = new_info
        end
    end
end

function timestep:new_spline_fish(info, data, num, spline_id, new_fish)
    self._group_id = self._group_id + 1
    if spline_id > 0 then
        self._spline_cd[spline_id] = 15
    end
    local life_time = data.life_time
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, num do
        self._fish_id = self._fish_id + 1
        local new_info = {
            id = self._fish_id,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = self._group_id,
            speed = info.speed,
            life_time = life_time,
            time = 0,
            data = data,
            matrix_id = matrix_id,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[self._fish_id] = new_info
    end
end

function timestep:update_spline_fish(spline_info, new_fish)
    local small_info = self._fish_pool[fish_type.small_fish]
    local small_pool = small_info.pool
    local big_info = self._fish_pool[fish_type.big_fish]
    local big_pool = big_info.pool
    local total_count = #small_pool + #big_pool
    if total_count > 0 then
        local rand_num = math.random(total_count)
        local info, num
        if rand_num <= #small_pool then
            info = small_pool[rand_num]
            num = math.random(small_info.rand_min, small_info.rand_max)
        else
            info = big_pool[rand_num - #small_pool]
            num = math.random(big_info.rand_min, big_info.rand_max)
        end
        self:new_spline_fish(info[1], info[2], num, spline_info.spline_id, new_fish)
    end
end

function timestep:update_spline(new_fish)
    local rand_spline, all_spline = {}, {}
    for k, v in pairs(self._spline) do
        if not self._spline_cd[k] then
            rand_spline[#rand_spline+1] = v
        end
        all_spline[#all_spline+1] = v
    end
    local spline_info
    if #rand_spline > 0 then
        spline_info = rand_spline[math.random(#rand_spline)]
    elseif #all_spline > 0 then
        spline_info = all_spline[math.random(#all_spline)]
    end
    if spline_info then
        self:update_spline_fish(spline_info, new_fish)
    end
end

function timestep:new_fish(info, data, num, time, new_fish, incount)
    self._group_id = self._group_id + 1
    local spline_id = info.spline_id
    local life_time = data.life_time
    if spline_id == 0 and life_time == 0 then
        local rand_spline, all_spline = {}, {}
        for k, v in pairs(camera_spline) do
            if not self._spline_cd[k] then
                rand_spline[#rand_spline+1] = k
            end
            all_spline[#all_spline+1] = k
        end
        if #rand_spline > 0 then
            spline_id = rand_spline[math.random(#rand_spline)]
        elseif #all_spline > 0 then
            spline_id = all_spline[math.random(#all_spline)]
        end
    end
    if spline_id > 0 then
        self._spline_cd[spline_id] = 10
    end
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    for i = 1, num do
        self._fish_id = self._fish_id + 1
        local new_info = {
            id = self._fish_id,
            fish_id = info.fish_id,
            spline_id = spline_id,
            group_id = self._group_id,
            speed = info.speed,
            life_time = life_time,
            time = time,
            data = data,
            matrix_id = matrix_id,
            incount = incount,
        }
        new_fish[#new_fish+1] = new_info
        self._fish[self._fish_id] = new_info
    end
end

function timestep:update_fish(etime, pool_info, new_fish)
    pool_info.time = pool_info.time + etime
    if self._use_follow_spline then
        if (pool_info.time >= pool_info.interval and pool_info.count < pool_info.max_count) or pool_info.count < pool_info.max_count * 10 // 8 then
            local pool = pool_info.pool
            if #pool > 0 then
                local info = pool[math.random(#pool)]
                local num = math.random(pool_info.rand_min, pool_info.rand_max)
                self:new_fish(info[1], info[2], num, 0, new_fish, true)
                pool_info.count = pool_info.count + num
            end
            pool_info.time = 0
        end
    end
    if #pool_info.ready > 0 then
        for k, v in ipairs(pool_info.ready) do
            local num = math.random(pool_info.rand_min, pool_info.rand_max)
            local info = v[1]
            local time = self._game_time - info.time
            self:new_fish(info, v[2], num, time, new_fish)
            -- NOTICE: don't count fish
        end
        pool_info.ready = {}
    end
end

function timestep:new_boss(info, data, time, new_fish)
    self._group_id = self._group_id + 1
    local spline_id = info.spline_id
    local life_time = data.life_time
    if spline_id == 0 and life_time == 0 then
        local rand_spline, all_spline = {}, {}
        for k, v in pairs(camera_spline) do
            if not self._spline_cd[k] then
                rand_spline[#rand_spline+1] = k
            end
            all_spline[#all_spline+1] = k
        end
        if #rand_spline > 0 then
            spline_id = rand_spline[math.random(#rand_spline)]
        elseif #all_spline > 0 then
            spline_id = all_spline[math.random(#all_spline)]
        end
    end
    if spline_id > 0 then
        self._spline_cd[spline_id] = 10
    end
    if life_time == 0 and spline_id > 0 and info.speed > 0 then
        life_time = spline_data[spline_id].length / info.speed
    end
    local matrix_id = info.matrix_id
    if matrix_id == 0 and #matrix_data > 0 then
        matrix_id = matrix_data[math.random(#matrix_data)]
    end
    self._fish_id = self._fish_id + 1
    local new_info = {
        id = self._fish_id,
        fish_id = info.fish_id,
        spline_id = spline_id,
        group_id = self._group_id,
        speed = info.speed,
        life_time = life_time,
        time = time,
        data = data,
        matrix_id = matrix_id,
    }
    new_fish[#new_fish+1] = new_info
    self._fish[self._fish_id] = new_info
end

function timestep:update_boss(pool_info, new_fish)
    if #pool_info.pool > 0 then
        for k, v in ipairs(pool_info.pool) do
            local info = v[1]
            local time = self._game_time - info.time
            self:new_boss(info, v[2], time, new_fish)
        end
        pool_info.pool = {}
    end
    if #pool_info.ready > 0 then
        for k, v in ipairs(pool_info.ready) do
            local info = v[1]
            local time = self._game_time - info.time
            self:new_boss(info, v[2], time, new_fish)
        end
        pool_info.ready = {}
    end
end

function timestep:delete_fish(info, hit)
    self._fish[info.id] = nil
    local pool_info = self._fish_pool[info.data.type]
    if pool_info.count and info.incount then
        pool_info.count = pool_info.count - 1
    end
    local event = self._event
    if event.info then
        if event.info.type == event_type.fight_boss and event.info.fish_id == info.fish_id then
            event.time = event.info.duration - 3
        end
        if event.data and hit then
            local data = event.data
            local skill_fish = data.skill_fish
            if skill_fish and skill_fish[info.id] then
                skill_fish[info.id] = nil
                data.hit_count = data.hit_count + 1
                if data.hit_count >= data.skill_info.hit_count then
                    data.skill_fish = nil
                    local del_count, del_msg = 0, ""
                    for k, v in pairs(skill_fish) do
                        self:delete_fish(v, false)
                        del_count = del_count + 1
                        del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
                    end
                    if data.fish then
                        local msg = string.pack(">I2>I4B", s_to_c.end_skill, data.fish.id, 1)
                        self:broadcast(msg)
                    end
                    if data.skill_index < #data.rand_skill then
                        data.skill_time = data.skill_data.interval
                        data.skill_status = skill_status.ready
                    else
                        data.skill_time = 0
                        data.skill_status = skill_status.done
                        if data.fish then
                            self:delete_fish(data.fish, false)
                            del_count = del_count + 1
                            del_msg = del_msg .. string.pack(">I4>I4", data.fish.id, data.fish.fish_id)
                            data.fish = nil
                        end
                    end
                    skynet_m.log(string.format("End skill %d", data.rand_skill[data.skill_index]))
                    if del_count > 0 then
                        -- TODO: send delete fish message to game server
                        del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
                        self:broadcast(del_msg)
                    end
                    data.skill_info = nil
                    data.fish_index = nil
                    data.hit_count = nil
                end
            end
        end
    end
end

function timestep:update()
    local now = skynet_m.now()
    local etime = (now - self._last_time) * 0.01
    self._last_time = now
    for k, v in pairs(self._spline_cd) do
        v = v - etime
        if v <= 0 then
            self._spline_cd[k] = nil
        end
    end
    local del_count, del_msg = 0, ""
    for k, v in pairs(self._fish) do
        v.time = v.time + etime
        if v.time >= v.life_time then
            self:delete_fish(v, false)
            del_count = del_count + 1
            del_msg = del_msg .. string.pack(">I4>I4", k, v.fish_id)
        end
    end
    if del_count > 0 then
        -- TODO: send delete fish message to game server
        del_msg = string.pack(">I2>I2", s_to_c.delete_fish, del_count) .. del_msg
        self:broadcast(del_msg)
    end
    local new_fish = {}
    local event = self._event
    local item = self._item
    if event.info or not util.empty(item) then
        if event.info then
            event.time = event.time + etime
            if event.info.type == event_type.fight_boss then
                if event.time >= event.info.duration then
                    -- self._game_time = event.info.time + (event.time - event.info.duration)
                    event.info = nil
                    event.time = 0
                    event.data = nil
                else
                    if event.data and event.data.skill_data then
                        skill_function[event.data.skill_status](self, event.data, etime, new_fish)
                    end
                end
            end
        end
        if not util.empty(item)  then
            for k, v in pairs(item) do
                v.time = v.time + etime
                if v.item_id == item_type.frozen then
                    if v.time >= FROZEN_TIME then
                        local msg = string.pack(">I2>I4", s_to_c.end_item, k)
                        self:broadcast(msg)
                        item[k] = nil
                    end
                end
            end
        end
    else
        self._game_time = self._game_time + etime
    end
    if self._game_time >= loop_time then
        self._game_time = self._game_time - loop_time
        self:loop()
    end
    -- skynet_m.log(string.format("Game time %f.", self._game_time))
    while event.index <= #event_data do
        local info = event_data[event.index]
        if self._game_time < info.time then
            break
        end
        event_function[info.type](self, info)
        event.index = event.index + 1
    end
    for k, v in ipairs({fish_type.small_fish, fish_type.big_fish}) do
        self:update_fish(etime, self._fish_pool[v], new_fish)
    end
    self:update_boss(self._fish_pool[fish_type.boss_fish], new_fish)
    self._spline_time = self._spline_time + etime
    if self._spline_time >= 10 then
        self:update_spline(new_fish)
        self._spline_time = self._spline_time - 10
    end
    -- util.dump(self._fish_pool, "fish_pool")
    local new_num = #new_fish
    if new_num > 0 then
        -- util.dump(new_fish, "new_fish")
        local new_msg = ""
        local client_msg = string.pack(">I2>I2", s_to_c.new_fish, new_num)
        local event_target = 0
        if event.info and event.info.type == event_type.fight_boss and event.info.fish_id > 0 and not event.data.fish then
            event_target = event.info.fish_id
        end
        for k, v in ipairs(new_fish) do
            if v.fish_id == event_target then
                event.data.fish = v
            end
            new_msg = new_msg .. string.pack("<I4<I2", v.id, v.fish_id)
            client_msg = client_msg .. string.pack(">I4>I4>I4>I4>f>f>I4", v.id, v.fish_id, v.spline_id, v.group_id, v.speed, v.time, v.matrix_id)
        end
        self:broadcast(client_msg)
        for i = new_num + 1, 100 do
            new_msg = new_msg .. string.pack("<I4<I2", 0, 0)
        end
        skynet_m.send_lua(game_message, "send_build_fish", {
            tableid = self._room_id,
            fish = new_msg,
        })
    end
    -- util.dump(self._fish, "fish")
end

function timestep:kick(user_id, agent)
    local info = self._user[user_id]
    if info and (not agent or info.agent == agent) then
        self._user[user_id] = nil
        self._pos[info.pos] = nil
        self._count = self._count-1
        if info.ready then
            self._ready_count = self._ready_count-1
            self:broadcast(string.pack(">I2>I4", s_to_c.leave_room, user_id))
        end
        if self._count == 0 then
            self:clear()
        end
    end
end

function timestep:process(user_id, data)
    local info = self._user[user_id]
    if not info then
        skynet_m.log(string.format("Can't find user %d.", user_id))
        return
    end
    local cmd = string.unpack(">I2", data)
    local func = c_to_s_i[cmd]
    if func then
        self[func](self, info, data)
        info.status_time = skynet_m.now()
    else
        skynet_m.log(string.format("Receive illegal cmd %d from user %d.", cmd, user_id))
    end
end

function timestep:broadcast(msg)
    for _, v in pairs(self._user) do
        if v.ready then
            skynet_m.send_lua(v.agent, "send", msg)
        end
    end
end

function timestep:ready(info, data)
    if info.ready then
        skynet_m.log(string.format("User %d is ready.", info.user_id))
    else
        self:broadcast(string.pack(">I2>I4B", s_to_c.join_room, info.user_id, info.pos))
        info.ready = true
        self._ready_count = self._ready_count + 1
        if self._ready_count == 1 then
            self:start()
        end
        local client_time = string.unpack(">d", data, 3)
        local msg = string.pack(">I2>d>fB", s_to_c.room_data, client_time, self._game_time, info.pos)
        msg = msg .. string.pack("B", self._ready_count - 1)
        for _, v in pairs(self._user) do
            if v.ready and v.user_id ~= info.user_id then
                msg = msg .. string.pack(">I4B", v.user_id, v.pos)
            end
        end
        local fish_msg, fish_count = "", 0
        for k, v in pairs(self._fish) do
            fish_msg = fish_msg .. string.pack(">I4>I4>I4>I4>f>f>I4", v.id, v.fish_id, v.spline_id, v.group_id, v.speed, v.time, v.matrix_id)
            fish_count = fish_count + 1
        end
        msg = msg .. string.pack(">I2", fish_count) .. fish_msg
        local event = self._event
        if event.info then
            if event.info.type == event_type.fight_boss then
                msg = msg .. string.pack(">I4>f", event.info.id, event.info.duration - event.time)
                local edata = event.data
                if edata and edata.fish then
                    msg = msg .. string.pack(">I4>I2", edata.fish.id, edata.rand_skill[edata.skill_index])
                else
                    msg = msg .. string.pack(">I4", 0)
                end
            else
                skynet_m.log(string.format("Can't get trigger event %d left time.", event.info.id))
                msg = msg .. string.pack(">I4", event.info.id)
            end
        else
            msg = msg .. string.pack(">I4", 0)
        end
        skynet_m.send_lua(info.agent, "send", msg)
    end
end

function timestep:quit(info, data)
    skynet_m.send_lua(agent_mgr, "quit", info.user_id, error_code.ok)
end

function timestep:fire(info, data)
    local self_id, angle, multi, kind = string.unpack(">I4>f>I4>I4", data, 3)
    self._bullet_id = self._bullet_id + 1
    info.bullet[self_id] = self._bullet_id
    skynet_m.send_lua(game_message, "send_fire", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        bullet = {
            id = self._bullet_id,
            kind = kind,
            multi = multi,
            power = 1,
            expTime = 0,
        },
    })
    self._bullet[self._bullet_id] = {
        id = self._bullet_id,
        self_id = self_id,
        kind = kind,
        angle = angle,
        multi = multi,
    }
end

function timestep:hit(info, data)
    local self_id, fishid, multi = string.unpack(">I4>I4>I4", data, 3)
    local bulletid = info.bullet[self_id]
    if not bulletid then
        skynet_m.log(string.format("Can't find bullet %d when user %d hit fish %d.", self_id, info.user_id, fishid))
        return
    end
    info.bullet[self_id] = nil
    skynet_m.send_lua(game_message, "send_catch_fish", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        bulletid = bulletid,
        fishid = fishid,
        bulletMulti = multi,
    })
end

function timestep:heart_beat(info, data)
    local client_time = string.unpack(">d", data, 3)
    local msg = string.pack(">I2>d>f", s_to_c.heart_beat, client_time, self._game_time)
    skynet_m.send_lua(info.agent, "send", msg)
end

function timestep:use_item(info, data)
    local item_id = string.unpack(">I2", data, 3)
    skynet_m.send_lua(game_message, "send_use_item", {
        tableid = self._room_id,
        seatid = info.pos - 1,
        userid = info.user_id,
        itemid = item_id,
    })
end

function timestep:on_fire(info)
    local binfo = info.bullet
    if info.code ~= 0 then
        skynet_m.log(string.format("User %d fire bullet %d fail.", info.userid, binfo.id))
        return
    end
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Fire can't find user %d.", info.userid))
        return
    end
    local bullet = self._bullet[binfo.id]
    if binfo.kind ~= bullet.kind or binfo.multi ~= bullet.multi then
        skynet_m.log(string.format("Fire info is different."))
    end
    self._bullet[binfo.id] = nil
    local msg = string.pack(">I2>I4>I4>I4B>f>I4>I4>I8", s_to_c.fire, bullet.id, bullet.self_id, binfo.kind, user_info.pos, bullet.angle, binfo.multi, info.costGold, info.fishScore)
    self:broadcast(msg)
end

function timestep:on_dead(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Dead can't find user %d.", info.userid))
        return
    end
    local fish_info = self._fish[info.fishid]
    if fish_info then
        self:delete_fish(fish_info, true)
        -- NOTICE: no bullet self_id info
        local msg = string.pack(">I2B>I4>I4>>I4I2>I2>I4>I8", s_to_c.dead, user_info.pos, info.bulletid, info.fishid, fish_info.fish_id, info.multi, info.bulletMulti, info.winGold, info.fishScore)
        self:broadcast(msg)
    end
end

function timestep:on_set_cannon(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Set cannon can't find user %d.", info.userid))
        return
    end
    local msg = string.pack(">I2>I2", s_to_c.set_cannon, info.cannon)
    self:broadcast(msg)
end

function timestep:on_use_item(info)
    local user_info = self._user[info.userid]
    if not user_info then
        skynet_m.log(string.format("Use item can't find user %d.", info.userid))
        return
    end
    self._item_id = self._item_id + 1
    local item_info = {
        id = self._item_id,
        item_id = info.itemid,
        time = 0,
        use_id = info.userid,
    }
    self._item[self._item_id] = item_info
    local msg = string.pack(">I2>I4>I4>I2", s_to_c.use_item, info.useid, self._item_id, info.itemid)
    self:broadcast(msg)
end

return {__index=timestep}