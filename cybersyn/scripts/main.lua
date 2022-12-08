--By Mami
local floor = math.floor
local ceil = math.ceil
local table_insert = table.insert


---@param map_data MapData
---@param stop LuaEntity
---@param comb LuaEntity
local function on_depot_built(map_data, stop, comb)
	--NOTE: only place where new Depot
	local depot = {
		entity_stop = stop,
		entity_comb = comb,
		available_train_id = nil,
	}
	local depot_id = stop.unit_number--[[@as uint]]
	map_data.depots[depot_id] = depot
	interface_raise_depot_created(depot_id)
end

---@param map_data MapData
---@param depot_id uint
---@param depot Depot
local function on_depot_broken(map_data, depot_id, depot)
	local train_id = depot.available_train_id
	if train_id then
		local train = map_data.trains[train_id]
		lock_train(train.entity)
		send_lost_train_alert(train.entity, depot.entity_stop.backer_name)
		remove_train(map_data, train_id, train)
	end
	map_data.depots[depot_id] = nil
	interface_raise_depot_removed(depot_id, depot)
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb LuaEntity
local function on_refueler_built(map_data, stop, comb)
	--NOTE: only place where new Depot
	local refueler = {
		entity_stop = stop,
		entity_comb = comb,
		trains_total = 0,
		accepted_layouts = {},
		layout_pattern = {},
		--allows_all_trains = set_refueler_from_comb,
		--priority = set_refueler_from_comb,
		--network_name = set_refueler_from_comb,
		--network_flag = set_refueler_from_comb,
	}
	set_refueler_from_comb(mod_settings, refueler)
	local id = stop.unit_number--[[@as uint]]
	map_data.refuelers[id] = refueler
	update_stop_if_auto(map_data, refueler, false)
	if refueler.network_name then
		local network = map_data.to_refuelers[refueler.network_name]
		if not network then
			network = {}
			map_data.to_refuelers[refueler.network_name] = network
		end
		network[id] = true
	end
	interface_raise_refueler_created(id)
end
---@param map_data MapData
---@param refueler_id uint
---@param refueler Refueler
local function on_refueler_broken(map_data, refueler_id, refueler)
	if refueler.trains_total > 0 then
		--search for trains coming to the destroyed refueler
		for train_id, train in pairs(map_data.trains) do
			local is_f = train.refueler_id == refueler_id
			if is_f then
				if not train.se_is_being_teleported then
					remove_train(map_data, train_id, train)
					lock_train(train.entity)
					send_lost_train_alert(train.entity, train.depot_name)
				else
					train.se_awaiting_removal = train_id
				end
			end
		end
	end
	if refueler.network_name then
		local network = map_data.to_refuelers[refueler.network_name]
		network[refueler_id] = nil
		if next(network) == nil then
			map_data.to_refuelers[refueler.network_name] = nil
		end
	end
	map_data.stations[refueler_id] = nil
	interface_raise_refueler_removed(refueler_id, refueler)
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb1 LuaEntity
---@param comb2 LuaEntity
local function on_station_built(map_data, stop, comb1, comb2)
	--NOTE: only place where new Station
	local station = {
		entity_stop = stop,
		entity_comb1 = comb1,
		entity_comb2 = comb2,
		--is_p = set_station_from_comb_state,
		--is_r = set_station_from_comb_state,
		--allows_all_trains = set_station_from_comb_state,
		deliveries_total = 0,
		last_delivery_tick = map_data.total_ticks,
		priority = 0,
		item_priotity = nil,
		r_threshold = 0,
		locked_slots = 0,
		--network_name = set_station_from_comb_state,
		network_flag = 0,
		wagon_combs = nil,
		deliveries = {},
		accepted_layouts = {},
		layout_pattern = nil,
		tick_signals = nil,
		item_p_counts = {},
		item_thresholds = nil,
		display_state = 0,
	}
	set_station_from_comb_state(station)
	local id = stop.unit_number--[[@as uint]]
	map_data.stations[id] = station
	map_data.warmup_station_ids[#map_data.warmup_station_ids + 1] = id

	update_stop_if_auto(map_data, station, true)
	interface_raise_station_created(id)
end
---@param map_data MapData
---@param station_id uint
---@param station Station
local function on_station_broken(map_data, station_id, station)
	if station.deliveries_total > 0 then
		--search for trains coming to the destroyed station
		for train_id, train in pairs(map_data.trains) do
			local is_r = train.r_station_id == station_id
			local is_p = train.p_station_id == station_id
			if is_p or is_r then

				local is_p_in_progress = train.status == STATUS_TO_P or train.status == STATUS_P
				local is_r_in_progress = is_p_in_progress or train.status == STATUS_TO_R or train.status == STATUS_R
				if (is_p and is_p_in_progress) or (is_r and is_r_in_progress) then
					--train is attempting delivery to a stop that was destroyed, stop it
					on_failed_delivery(map_data, train_id, train)
					if not train.se_is_being_teleported then
						remove_train(map_data, train_id, train)
						lock_train(train.entity)
						send_lost_train_alert(train.entity, train.depot_name)
					else
						train.se_awaiting_removal = train_id
					end
				end
			end
		end
	end
	map_data.stations[station_id] = nil
	interface_raise_station_removed(station_id, station)
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb_operation string
---@param comb_forbidden LuaEntity?
local function search_for_station_combinator(map_data, stop, comb_operation, comb_forbidden)
	local pos_x = stop.position.x
	local pos_y = stop.position.y
	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if
		entity.valid and entity.name == COMBINATOR_NAME and
		entity ~= comb_forbidden and map_data.to_stop[entity.unit_number] == stop
		then
			local param = get_comb_params(entity)
			if param.operation == comb_operation then
				return entity
			end
		end
	end
end

---@param map_data MapData
---@param comb LuaEntity
local function on_combinator_built(map_data, comb)
	local pos_x = comb.position.x
	local pos_y = comb.position.y

	local search_area
	if comb.direction == defines.direction.north or comb.direction == defines.direction.south then
		search_area = {
			{pos_x - 1.5, pos_y - 2},
			{pos_x + 1.5, pos_y + 2}
		}
	else
		search_area = {
			{pos_x - 2, pos_y - 1.5},
			{pos_x + 2, pos_y + 1.5}
		}
	end
	local stop = nil
	local rail = nil
	local entities = comb.surface.find_entities(search_area)
	for _, cur_entity in pairs(entities) do
		if cur_entity.valid then
			if cur_entity.name == "train-stop" then
				--NOTE: if there are multiple stops we take the later one
				stop = cur_entity
			elseif cur_entity.type == "straight-rail" then
				rail = cur_entity
			end
		end
	end

	local out = comb.surface.create_entity({
		name = COMBINATOR_OUT_NAME,
		position = comb.position,
		force = comb.force
	})
	assert(out, "cybersyn: could not spawn combinator controller")
	comb.connect_neighbour({
		target_entity = out,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
		wire = defines.wire_type.green,
	})
	comb.connect_neighbour({
		target_entity = out,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
		wire = defines.wire_type.red,
	})

	local control = get_comb_control(comb)
	local params = control.parameters
	local op = params.operation

	if op == MODE_DEFAULT then
		op = MODE_PRIMARY_IO
		params.operation = op
		params.first_signal = NETWORK_SIGNAL_DEFAULT
		control.parameters = params
	elseif op ~= MODE_PRIMARY_IO and op ~= MODE_SECONDARY_IO and op ~= MODE_DEPOT and op ~= MODE_REFUELER and op ~= MODE_WAGON_MANIFEST then
		op = MODE_PRIMARY_IO
		params.operation = op
		control.parameters = params
	end

	map_data.to_comb[comb.unit_number] = comb
	map_data.to_comb_params[comb.unit_number] = params
	map_data.to_output[comb.unit_number] = out
	map_data.to_stop[comb.unit_number] = stop

	if op == MODE_WAGON_MANIFEST then
		if rail then
			update_stop_from_rail(map_data, rail, nil, true)
		end
	elseif stop then
		local id = stop.unit_number--[[@as uint]]
		local station = map_data.stations[id]
		local depot = map_data.depots[id]
		local refueler = map_data.refuelers[id]
		if op == MODE_DEPOT then
			if refueler then
				on_refueler_broken(map_data, id, refueler)
			end
			if not station and not depot then
				on_depot_built(map_data, stop, comb)
			end
		elseif op == MODE_REFUELER then
			if not station and not depot and not refueler then
				on_refueler_built(map_data, stop, comb)
			end
		elseif op == MODE_SECONDARY_IO then
			if station and not station.entity_comb2 then
				station.entity_comb2 = comb
			end
		elseif op == MODE_PRIMARY_IO then
			if refueler then
				on_refueler_broken(map_data, id, refueler)
			end
			if depot then
				on_depot_broken(map_data, id, depot)
			end
			if not station then
				local comb2 = search_for_station_combinator(map_data, stop, MODE_SECONDARY_IO, comb)
				on_station_built(map_data, stop, comb, comb2)
			end
		end
	end
end
---@param map_data MapData
---@param comb LuaEntity
---@param network_name string?
function on_combinator_network_updated(map_data, comb, network_name)
	local stop = map_data.to_stop[comb.unit_number]

	if stop and stop.valid then
		local id = stop.unit_number
		local station = map_data.stations[id]
		if station then
			if station.entity_comb1 == comb then
				station.network_name = network_name
			end
		else
			local depot = map_data.depots[id]
			if depot then
				if depot.entity_comb == comb then
					local train_id = depot.available_train_id
					if train_id then
						local train = map_data.trains[train_id]
						remove_available_train(map_data, train_id, train)
						add_available_train_to_depot(map_data, mod_settings, train_id, train, id, depot)
						interface_raise_train_status_changed(train_id, STATUS_D, STATUS_D)
					end
				end
			else
				local refueler = map_data.refuelers[id]
				if refueler and refueler.entity_comb == comb then
					if refueler.network_name then
						local network = map_data.to_refuelers[refueler.network_name]
						network[id] = nil
						if next(network) == nil then
							map_data.to_refuelers[refueler.network_name] = nil
						end
					end
					refueler.network_name = network_name
					if network_name then
						local network = map_data.to_refuelers[network_name]
						if network == nil then
							network = {}
							map_data.to_refuelers[network_name] = network
						end
						network[id] = true
					end
				end
			end
		end
	end
end
---@param map_data MapData
---@param comb LuaEntity
function on_combinator_broken(map_data, comb)
	--NOTE: we do not check for wagon manifest combinators and update their stations, it is assumed they will be lazy deleted later
	---@type uint
	local comb_id = comb.unit_number
	local out = map_data.to_output[comb_id]
	local stop = map_data.to_stop[comb_id]

	if stop and stop.valid then
		local id = stop.unit_number--[[@as uint]]
		local station = map_data.stations[id]
		if station then
			if station.entity_comb1 == comb then
				on_station_broken(map_data, id, station)
				on_stop_built(map_data, stop, comb)
			elseif station.entity_comb2 == comb then
				station.entity_comb2 = search_for_station_combinator(map_data, stop, MODE_SECONDARY_IO, comb)
			end
		else
			local depot = map_data.depots[id]
			if depot then
				if depot.entity_comb == comb then
					on_depot_broken(map_data, id, depot)
					on_stop_built(map_data, stop, comb)
				end
			else
				local refueler = map_data.refuelers[id]
				if refueler and refueler.entity_comb == comb then
					on_refueler_broken(map_data, id, refueler)
					on_stop_built(map_data, stop, comb)
				end
			end
		end
	end

	if out and out.valid then
		out.destroy()
	end
	map_data.to_comb[comb_id] = nil
	map_data.to_output[comb_id] = nil
	map_data.to_stop[comb_id] = nil
	map_data.to_comb_params[comb_id] = nil
end

---@param map_data MapData
---@param comb LuaEntity
function combinator_update(map_data, comb)
	local unit_number = comb.unit_number--[[@as uint]]
	local control = get_comb_control(comb)
	local params = control.parameters
	local old_params = map_data.to_comb_params[unit_number]
	local has_changed = false

	if params.operation ~= old_params.operation then
		if (old_params.operation == MODE_PRIMARY_IO) and (params.operation == MODE_PRIMARY_IO_ACTIVE or params.operation == MODE_PRIMARY_IO_FAILED_REQUEST) then
			--make sure only MODE_PRIMARY_IO gets stored on map_data.to_comb_params
			params.operation = MODE_PRIMARY_IO
		else
			--NOTE: This is rather dangerous, we may need to actually implement operation changing
			on_combinator_broken(map_data, comb)
			on_combinator_built(map_data, comb)
			interface_raise_combinator_changed(comb, old_params)
			return
		end
	end
	local new_signal = params.first_signal
	local old_signal = old_params.first_signal
	local new_network = new_signal and new_signal.name or nil
	local old_network = old_signal and old_signal.name or nil
	if new_network ~= old_network then
		has_changed = true
		on_combinator_network_updated(map_data, comb, new_network)
	end
	if params.second_constant ~= old_params.second_constant then
		has_changed = true
		local stop = map_data.to_stop[comb.unit_number]
		if stop then
			local id = stop.unit_number
			local station = map_data.stations[id]
			if station then
				local pre = station.allows_all_trains
				set_station_from_comb_state(station)
				if station.allows_all_trains ~= pre then
					update_stop_if_auto(map_data, station, true)
				end
			else
				local refueler = map_data.refuelers[id]
				if refueler then
					local pre = refueler.allows_all_trains
					set_refueler_from_comb(mod_settings, refueler)
					if refueler.allows_all_trains ~= pre then
						update_stop_if_auto(map_data, refueler, false)
					end
				end
			end
		end
	end
	if has_changed then
		map_data.to_comb_params[unit_number] = params
		interface_raise_combinator_changed(comb, old_params)
	end
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb_forbidden LuaEntity?
function on_stop_built(map_data, stop, comb_forbidden)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local comb2 = nil
	local comb1 = nil
	local depot_comb = nil
	local refueler_comb = nil
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if entity.valid and entity ~= comb_forbidden and entity.name == COMBINATOR_NAME and map_data.to_stop[entity.unit_number] == nil then
			map_data.to_stop[entity.unit_number] = stop
			local param = get_comb_params(entity)
			local op = param.operation
			if op == MODE_PRIMARY_IO then
				comb1 = entity
			elseif op == MODE_SECONDARY_IO then
				comb2 = entity
			elseif op == MODE_DEPOT then
				depot_comb = entity
			elseif op == MODE_REFUELER then
				refueler_comb = entity
			end
		end
	end
	if comb1 then
		on_station_built(map_data, stop, comb1, comb2)
	elseif depot_comb then
		on_depot_built(map_data, stop, depot_comb)
	elseif refueler_comb then
		on_refueler_built(map_data, stop, refueler_comb)
	end
end
---@param map_data MapData
---@param stop LuaEntity
local function on_stop_broken(map_data, stop)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if entity.valid and map_data.to_stop[entity.unit_number] == stop then
			map_data.to_stop[entity.unit_number] = nil
		end
	end

	local id = stop.unit_number--[[@as uint]]
	local station = map_data.stations[id]
	if station then
		on_station_broken(map_data, id, station)
	else
		local depot = map_data.depots[id]
		if depot then
			on_depot_broken(map_data, id, depot)
		else
			local refueler = map_data.refuelers[id]
			if refueler then
				on_refueler_broken(map_data, id, refueler)
			end
		end
	end
end
---@param map_data MapData
---@param stop LuaEntity
---@param old_name string
local function on_stop_rename(map_data, stop, old_name)
	--search for trains coming to the renamed station
	local station_id = stop.unit_number--[[@as uint]]
	local station = map_data.stations[station_id]
	if station and station.deliveries_total > 0 then
		for train_id, train in pairs(map_data.trains) do
			local is_p = train.p_station_id == station_id
			local is_r = train.r_station_id == station_id
			if is_p or is_r then
				local is_p_in_progress = train.status == STATUS_TO_P or train.status == STATUS_P
				local is_r_in_progress = is_p_in_progress or train.status == STATUS_TO_R or train.status == STATUS_R
				if is_r and is_r_in_progress then
					local r_station = map_data.stations[train.r_station_id]
					if not train.se_is_being_teleported then
						rename_manifest_schedule(train.entity, r_station.entity_stop, old_name)
					else
						train.se_awaiting_rename = {r_station.entity_stop, old_name}
					end
				elseif is_p and is_p_in_progress then
					--train is attempting delivery to a stop that was renamed
					local p_station = map_data.stations[train.p_station_id]
					if not train.se_is_being_teleported then
						rename_manifest_schedule(train.entity, p_station.entity_stop, old_name)
					else
						train.se_awaiting_rename = {p_station.entity_stop, old_name}
					end
				end
			end
		end
	else
		local depot = map_data.depots[station_id]
		if depot and depot.available_train_id then
			local train = map_data.trains[depot.available_train_id--[[@as uint]]]
			train.depot_name = stop.backer_name
			--train.se_depot_surface_i = stop.surface.index
		end
	end
end


---@param map_data MapData
local function find_and_add_all_stations_from_nothing(map_data)
	for _, surface in pairs(game.surfaces) do
		local entities = surface.find_entities_filtered({name = COMBINATOR_NAME})
		for k, comb in pairs(entities) do
			if comb.valid then
				on_combinator_built(map_data, comb)
			end
		end
	end
end


local function on_built(event)
	local entity = event.entity or event.created_entity
	if not entity or not entity.valid then return end

	if entity.name == "train-stop" then
		on_stop_built(global, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_built(global, entity)
	elseif entity.type == "inserter" then
		update_stop_from_inserter(global, entity)
	elseif entity.type == "pump" then
		update_stop_from_pump(global, entity)
	elseif entity.type == "straight-rail" then
		update_stop_from_rail(global, entity)
	end
end
local function on_broken(event)
	local entity = event.entity
	if not entity or not entity.valid then return end

	if entity.name == "train-stop" then
		on_stop_broken(global, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_broken(global, entity)
	elseif entity.type == "inserter" then
		update_stop_from_inserter(global, entity, entity)
	elseif entity.type == "pump" then
		update_stop_from_pump(global, entity, entity)
	elseif entity.type == "straight-rail" then
		update_stop_from_rail(global, entity, nil)
	elseif entity.train then
		local train_id = entity.train.id
		local train = global.trains[train_id]
		if train then
			on_train_broken(global, train_id, train)
		end
	end
end
local function on_rotate(event)
	local entity = event.entity or event.created_entity
	if not entity or not entity.valid then return end

	if entity.type == "inserter" then
		update_stop_from_inserter(global, entity)
	end
end

local function on_surface_removed(event)
	local surface = game.surfaces[event.surface_index]
	if surface then
		local train_stops = surface.find_entities_filtered({type = "train-stop"})
		for _, entity in pairs(train_stops) do
			if entity.valid and entity.name == "train-stop" then
				on_stop_broken(global, entity)
			end
		end
	end
end


local function on_paste(event)
	local entity = event.destination
	if not entity or not entity.valid then return end

	if entity.name == COMBINATOR_NAME then
		combinator_update(global, entity)
	end
end

local function on_rename(event)
	if event.entity.name == "train-stop" then
		on_stop_rename(global, event.entity, event.old_name)
	end
end


local function on_settings_changed(event)
	mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value --[[@as double]]
	mod_settings.update_rate = settings.global["cybersyn-update-rate"].value --[[@as int]]
	mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value--[[@as int]]
	mod_settings.network_flag = settings.global["cybersyn-network-flag"].value--[[@as int]]
	mod_settings.fuel_threshold = settings.global["cybersyn-fuel-threshold"].value--[[@as double]]
	mod_settings.depot_bypass_enabled = settings.global["cybersyn-depot-bypass-enabled"].value--[[@as boolean]]
	mod_settings.warmup_time = settings.global["cybersyn-warmup-time"].value--[[@as double]]
	mod_settings.stuck_train_time = settings.global["cybersyn-stuck-train-time"].value--[[@as double]]
	if event.setting == "cybersyn-ticks-per-second" then
		if mod_settings.tps > DELTA then
			local nth_tick = ceil(60/mod_settings.tps)--[[@as uint]];
			script.on_nth_tick(nth_tick, function()
				tick(global, mod_settings)
			end)
		else
			script.on_nth_tick(nil)
		end
	end
	interface_raise_on_mod_settings_changed(event)
end

local function setup_se_compat()
	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil
	if not IS_SE_PRESENT then return end

	local se_on_train_teleport_finished_event = remote.call("space-exploration", "get_on_train_teleport_finished_event")
	local se_on_train_teleport_started_event = remote.call("space-exploration", "get_on_train_teleport_started_event")

	---@param event {}
	script.on_event(se_on_train_teleport_started_event, function(event)
		---@type MapData
		local map_data = global
		local old_id = event.old_train_id_1
		--NOTE: this is not guaranteed to be unique, it should be fine since the window of time for another train to mistakenly steal this train's event data is miniscule
		--NOTE: please SE dev if you read this fix the issue where se_on_train_teleport_finished_event is returning the wrong old train id
		local train_unique_identifier = event.train.front_stock.backer_name

		local train = map_data.trains[old_id]
		if not train then return end
		--NOTE: IMPORTANT, until se_on_train_teleport_finished_event is called map_data.trains[old_id] will reference an invalid train entity; our events have either been set up to account for this or should be impossible to trigger until teleportation is finished
		train.se_is_being_teleported = true
		map_data.se_tele_old_id[train_unique_identifier] = old_id
		interface_raise_train_teleport_started(old_id)
	end)
	---@param event {}
	script.on_event(se_on_train_teleport_finished_event, function(event)
		---@type MapData
		local map_data = global
		---@type LuaTrain
		local train_entity = event.train
		---@type uint
		local new_id = train_entity.id
		local old_surface_index = event.old_surface_index
		local train_unique_identifier = event.train.front_stock.backer_name

		--NOTE: event.old_train_id_1 from this event is useless, it's for one of the many transient trains SE spawns while teleporting the old train, only se_on_train_teleport_started_event returns the correct old train id
		--NOTE: please SE dev if you read this fix the issue where se_on_train_teleport_finished_event is returning the wrong old train id
		local old_id = map_data.se_tele_old_id[train_unique_identifier]
		map_data.se_tele_old_id[train_unique_identifier] = nil
		local train = map_data.trains[old_id]
		if not train then return end

		if train.is_available then
			local network = map_data.available_trains[train.network_name--[[@as string]]]
			if network then
				network[new_id] = true
				network[old_id] = nil
			end
		end

		map_data.trains[new_id] = train
		map_data.trains[old_id] = nil
		train.se_is_being_teleported = nil
		train.entity = train_entity

		if train.se_awaiting_removal then
			remove_train(map_data, train.se_awaiting_removal, train)
			lock_train(train.entity)
			send_lost_train_alert(train.entity, train.depot_name)
			return
		elseif train.se_awaiting_rename then
			rename_manifest_schedule(train.entity, train.se_awaiting_rename[1], train.se_awaiting_rename[2])
			train.se_awaiting_rename = nil
		end

		if not (train.status == STATUS_TO_P or train.status == STATUS_TO_R) then return end

		local schedule = train_entity.schedule
		if schedule then
			if train.status == STATUS_TO_P or train.status == STATUS_TO_R then
				local p_station = map_data.stations[train.p_station_id]
				local p_name = p_station.entity_stop.backer_name
				local p_surface_i = p_station.entity_stop.surface.index
				local r_station = map_data.stations[train.r_station_id]
				local r_name = r_station.entity_stop.backer_name
				local r_surface_i = r_station.entity_stop.surface.index
				local records = schedule.records
				local i = schedule.current
				while i <= #records do
					if records[i].station == p_name and p_surface_i ~= old_surface_index then
						table_insert(records, i, create_direct_to_station_order(p_station.entity_stop))
						i = i + 1
					elseif records[i].station == r_name and r_surface_i ~= old_surface_index then
						table_insert(records, i, create_direct_to_station_order(r_station.entity_stop))
						i = i + 1
					end
					i = i + 1
				end
				train_entity.schedule = schedule
			elseif train.status == STATUS_TO_F then
				local refueler = map_data.refuelers[train.refueler_id]
				local f_name = refueler.entity_stop.backer_name
				local f_surface_i = refueler.entity_stop.surface.index
				local records = schedule.records
				local i = schedule.current
				while i <= #records do
					if records[i].station == f_name and f_surface_i ~= old_surface_index then
						table_insert(records, i, create_direct_to_station_order(refueler.entity_stop))
						i = i + 1
					end
					i = i + 1
				end
				train_entity.schedule = schedule
			end
		end
		interface_raise_train_teleported(new_id, old_id)
	end)
end


local filter_built = {
	{filter = "name", name = "train-stop"},
	{filter = "name", name = COMBINATOR_NAME},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
	{filter = "type", type = "straight-rail"},
}
local filter_broken = {
	{filter = "name", name = "train-stop"},
	{filter = "name", name = COMBINATOR_NAME},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
	{filter = "type", type = "straight-rail"},
	{filter = "rolling-stock"},
}
local function main()
	mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value --[[@as double]]
	mod_settings.update_rate = settings.global["cybersyn-update-rate"].value --[[@as int]]
	mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value--[[@as int]]
	mod_settings.network_flag = settings.global["cybersyn-network-flag"].value--[[@as int]]
	mod_settings.fuel_threshold = settings.global["cybersyn-fuel-threshold"].value--[[@as double]]
	mod_settings.warmup_time = settings.global["cybersyn-warmup-time"].value--[[@as double]]
	mod_settings.stuck_train_time = settings.global["cybersyn-stuck-train-time"].value--[[@as double]]
	mod_settings.depot_bypass_enabled = settings.global["cybersyn-depot-bypass-enabled"].value--[[@as boolean]]

	mod_settings.missing_train_alert_enabled = true
	mod_settings.stuck_train_alert_enabled = true
	mod_settings.react_to_nonempty_train_in_depot = true
	mod_settings.react_to_train_at_incorrect_station = true
	mod_settings.react_to_train_early_to_depot = true

	--NOTE: There is a concern that it is possible to build or destroy important entities without one of these events being triggered, in which case the mod will have undefined behavior
	script.on_event(defines.events.on_built_entity, on_built, filter_built)
	script.on_event(defines.events.on_robot_built_entity, on_built, filter_built)
	script.on_event({defines.events.script_raised_built, defines.events.script_raised_revive, defines.events.on_entity_cloned}, on_built)

	script.on_event(defines.events.on_player_rotated_entity, on_rotate)

	script.on_event(defines.events.on_pre_player_mined_item, on_broken, filter_broken)
	script.on_event(defines.events.on_robot_pre_mined, on_broken, filter_broken)
	script.on_event(defines.events.on_entity_died, on_broken, filter_broken)
	script.on_event(defines.events.script_raised_destroy, on_broken)

	script.on_event({defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared}, on_surface_removed)

	script.on_event(defines.events.on_entity_settings_pasted, on_paste)

	if mod_settings.tps > DELTA then
		local nth_tick = ceil(60/mod_settings.tps)--[[@as uint]];
		script.on_nth_tick(nth_tick, function()
			tick(global, mod_settings)
		end)
	else
		script.on_nth_tick(nil)
	end

	script.on_event(defines.events.on_train_created, on_train_built)
	script.on_event(defines.events.on_train_changed_state, on_train_changed)

	script.on_event(defines.events.on_entity_renamed, on_rename)

	script.on_event(defines.events.on_runtime_mod_setting_changed, on_settings_changed)

	register_gui_actions()

	script.on_init(function()
		init_global()
		setup_se_compat()
	end)

	script.on_configuration_changed(on_config_changed)

	script.on_load(function()
		setup_se_compat()
	end)
end


main()
