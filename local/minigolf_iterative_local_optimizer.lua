local MOUSE_X = "Mouse Position X"
local MOUSE_Y = "Mouse Position Y"
local MOUSE_DX = "Mouse Speed X"
local MOUSE_DY = "Mouse Speed Y"
local MOUSE_LEFT = "Mouse Left Button"

local X_MIN, X_MAX, X_NEUTRAL = 0, 2560, 1280
local Y_MIN, Y_MAX, Y_NEUTRAL = 0, 2048, 1024

local LEGAL_X_MIN, LEGAL_X_MAX = 12, 2536
local LEGAL_Y_MIN, LEGAL_Y_MAX = 260, 2018

-- limitation from old Windows
local MAX_POSITION_DELTA = 255
local MAX_EXPLICIT_SPEED = 180

local HOLE_DOMAIN = "Physical RAM"
local HOLE_ADDRESS = 0x023DB7B8
local CANDIDATE_INPUT_SPAN = 32
local SNAPSHOT_TAIL = 8

local STRATEGY_FIRST = "First improvement (abort circle)"
local STRATEGY_BEST = "Best improvement (finish circle)"

local OBJECTIVE_OPTIMIZE = "Optimize existing hole-in-one"
local OBJECTIVE_FIND = "Find a hole-in-one"

local alive = true
local running = false
local stop_requested = false
local start_requested = false

local form
local current_x_box, current_y_box
local center_x_box, center_y_box
local radius_box, step_box, timeout_box
local branch_box
local nudge_x_box, nudge_y_box
local strategy_box
local objective_box
local keep_best_box
local progress_label
local best_label

local function log(msg)
	console.log(msg)
end

local function status(msg)
	if progress_label then forms.settext(progress_label, msg) end
	log(msg)
end

local function round_nearest(v)
	if v >= 0 then return math.floor(v + 0.5) end
	return math.ceil(v - 0.5)
end

local function read_integer(handle)
	local v = tonumber(forms.gettext(handle))
	if not v or v ~= math.floor(v) then return nil end
	return v
end

local function get_video_size()
	local ok_w, w = pcall(function() return client.bufferwidth() end)
	local ok_h, h = pcall(function() return client.bufferheight() end)
	if not ok_w or not ok_h then return nil, nil end
	w, h = tonumber(w), tonumber(h)
	if not w or not h or w <= 0 or h <= 0 then return nil, nil end
	return math.floor(w + 0.5), math.floor(h + 0.5)
end

local function axis_from_input(input, exact_name, neutral)
	if not input then return neutral end
	local direct = input[exact_name]
	if direct ~= nil then
		local n = tonumber(direct)
		if n ~= nil then return math.floor(n + 0.5) end
	end
	for k, v in pairs(input) do
		if type(k) == "string" and #k >= #exact_name
			and k:sub(-#exact_name) == exact_name then
			local n = tonumber(v)
			if n ~= nil then return math.floor(n + 0.5) end
		end
	end
	return neutral
end

local function get_start_axis_position(move_frame)
	if move_frame <= 0 then return X_NEUTRAL, Y_NEUTRAL end
	local ok, input = pcall(function() return movie.getinput(move_frame - 1) end)
	if not ok or not input then return X_NEUTRAL, Y_NEUTRAL end
	return axis_from_input(input, MOUSE_X, X_NEUTRAL),
	axis_from_input(input, MOUSE_Y, Y_NEUTRAL)
end

local function write_mouse_frame(frame, x, y, speed_x, speed_y, left)
	tastudio.submitanalogchange(frame, MOUSE_X, x)
	tastudio.submitanalogchange(frame, MOUSE_Y, y)
	tastudio.submitanalogchange(frame, MOUSE_DX, speed_x)
	tastudio.submitanalogchange(frame, MOUSE_DY, speed_y)
	tastudio.submitinputchange(frame, MOUSE_LEFT, left)
end

local function cursor_delta_to_mickeys(cur_x, cur_y, target_x, target_y, video_w, video_h)
	local dx = round_nearest((target_x - cur_x) * video_w / (X_MAX - X_MIN))
	local dy = round_nearest((target_y - cur_y) * video_h / (Y_MAX - Y_MIN))
	return dx, dy
end

local function plan_axis_frame(pos, remaining, minv, maxv)
	if remaining == 0 then return pos, 0, 0 end
	local dir = remaining > 0 and 1 or -1
	local amount = math.abs(remaining)
	local room = dir > 0 and (maxv - pos) or (pos - minv)
	local position_amount = math.min(amount, MAX_POSITION_DELTA, room)
	local explicit_amount = math.min(amount, MAX_EXPLICIT_SPEED)
	if position_amount >= explicit_amount and position_amount > 0 then
		local moved = dir * position_amount
		return pos + moved, 0, moved
	end
	local moved = dir * explicit_amount
	local rearmed_pos = dir > 0 and minv or maxv
	return rearmed_pos, moved, moved
end

local function build_relative_path(start_axis_x, start_axis_y, dx, dy)
	local path = {}
	local axis_x, axis_y = start_axis_x, start_axis_y
	local rem_x, rem_y = dx, dy
	while rem_x ~= 0 or rem_y ~= 0 do
		local new_x, speed_x, moved_x = plan_axis_frame(axis_x, rem_x, X_MIN, X_MAX)
		local new_y, speed_y, moved_y = plan_axis_frame(axis_y, rem_y, Y_MIN, Y_MAX)
		path[#path + 1] = {
			x = new_x, y = new_y,
			speed_x = speed_x, speed_y = speed_y,
			moved_x = moved_x, moved_y = moved_y,
		}
		axis_x, axis_y = new_x, new_y
		rem_x = rem_x - moved_x
		rem_y = rem_y - moved_y

		-- don't see how anyone can ever hit this but better safe than sorry
		if #path > 64 then error("mouse path unexpectedly exceeded 64 frames") end
	end
	return path, axis_x, axis_y
end

local function fit_click_nudge(pos, requested, minv, maxv, press_speed, press_moved)
	if requested == 0 then return 0 end
	local function fits(n)
		if pos + n < minv or pos + n > maxv then return false end
		if press_speed ~= 0 then
			if math.abs(press_speed + n) > MAX_EXPLICIT_SPEED then return false end
		else
			if math.abs(press_moved + n) > MAX_POSITION_DELTA then return false end
		end
		return true
	end
	if fits(requested) then return requested end
	if fits(-requested) then return -requested end
	return nil
end

local function write_cleanup(frame, axis_x, axis_y)
	local sx, sy = 0, 0
	local stage_x, stage_y = X_NEUTRAL, Y_NEUTRAL
	if axis_x ~= X_NEUTRAL then
		sx = axis_x < X_NEUTRAL and 1 or -1
		stage_x = X_NEUTRAL + sx
	end
	if axis_y ~= Y_NEUTRAL then
		sy = axis_y < Y_NEUTRAL and 1 or -1
		stage_y = Y_NEUTRAL + sy
	end
	write_mouse_frame(frame, stage_x, stage_y, sx, sy, false)
	write_mouse_frame(frame + 1, X_NEUTRAL, Y_NEUTRAL, 0, 0, false)
end

local function build_candidate_plan(start_frame, start_axis_x, start_axis_y,cur_x, cur_y, target_x, target_y,video_w, video_h,requested_nudge_x, requested_nudge_y)
	local dx, dy = cursor_delta_to_mickeys(cur_x, cur_y, target_x, target_y, video_w, video_h)
	local path, final_axis_x, final_axis_y = build_relative_path(start_axis_x, start_axis_y, dx, dy)
	local arrival_frame = start_frame
	if #path > 0 then arrival_frame = start_frame + #path - 1 end
	local press_frame = arrival_frame
	local release_frame = press_frame + 1
	local press_speed_x, press_speed_y = 0, 0
	local press_moved_x, press_moved_y = 0, 0
	if #path > 0 then
		press_speed_x = path[#path].speed_x
		press_speed_y = path[#path].speed_y
		press_moved_x = path[#path].moved_x
		press_moved_y = path[#path].moved_y
	end
	local nudge_x = fit_click_nudge(
		final_axis_x, requested_nudge_x, X_MIN, X_MAX,
		press_speed_x, press_moved_x)
	local nudge_y = fit_click_nudge(
		final_axis_y, requested_nudge_y, Y_MIN, Y_MAX,
		press_speed_y, press_moved_y)
	if nudge_x == nil or nudge_y == nil then
		error("could not fit click nudge")
	end
	local cleanup_end = release_frame
	if final_axis_x ~= X_NEUTRAL or final_axis_y ~= Y_NEUTRAL then
		cleanup_end = release_frame + 2
	end
	return {
		target_x = target_x,
		target_y = target_y,
		dx = dx,
		dy = dy,
		path = path,
		final_axis_x = final_axis_x,
		final_axis_y = final_axis_y,
		press_frame = press_frame,
		release_frame = release_frame,
		nudge_x = nudge_x,
		nudge_y = nudge_y,
		cleanup_end = cleanup_end,
	}
end

local function queue_candidate_input(plan,start_frame)
	for f = start_frame, start_frame + CANDIDATE_INPUT_SPAN - 1 do
		write_mouse_frame(f, X_NEUTRAL, Y_NEUTRAL, 0, 0, false)
	end
	local path = plan.path
	local final_axis_x, final_axis_y = plan.final_axis_x, plan.final_axis_y
	for i, point in ipairs(path) do
		local f = start_frame + i - 1
		local left = (f == plan.press_frame)
		local x, y = point.x, point.y
		local speed_x, speed_y = point.speed_x, point.speed_y
		if left then
			x = x + plan.nudge_x
			y = y + plan.nudge_y
			if speed_x ~= 0 then speed_x = speed_x + plan.nudge_x end
			if speed_y ~= 0 then speed_y = speed_y + plan.nudge_y end
		end
		write_mouse_frame(f, x, y, speed_x, speed_y, left)
	end
	local first_stationary = (#path == 0) and start_frame or (start_frame + #path)
	for f = first_stationary, plan.release_frame do
		local left = (f == plan.press_frame)
		local x, y = final_axis_x, final_axis_y
		if left then
			x = x + plan.nudge_x
			y = y + plan.nudge_y
		end
		write_mouse_frame(f, x, y, 0, 0, left)
	end
	if final_axis_x ~= X_NEUTRAL or final_axis_y ~= Y_NEUTRAL then
		write_cleanup(plan.release_frame + 1, final_axis_x, final_axis_y)
	end
	if plan.cleanup_end >= start_frame + CANDIDATE_INPUT_SPAN then
		error("generated input exceeds CANDIDATE_INPUT_SPAN")
	end
end

local function apply_candidate(plan, start_frame)
	tastudio.clearinputchanges()
	queue_candidate_input(plan, start_frame)
	tastudio.applyinputchanges()
end

local function blank_mouse_horizon(start_frame, length)
	tastudio.clearinputchanges()
	for i = 0, length - 1 do
		write_mouse_frame(start_frame + i, X_NEUTRAL, Y_NEUTRAL, 0, 0, false)
	end
	tastudio.applyinputchanges()
end

local function read_hole()
	return memory.read_u8(HOLE_ADDRESS, HOLE_DOMAIN)
end

local function advance_search_frame()
	client.unpause()
	emu.frameadvance()
end

local function get_branch_info(branch_user_number)
	if not tastudio.getbranches then
		return nil, nil, "tastudio.getbranches() is unavailable"
	end
	local ok, branches = pcall(tastudio.getbranches)
	if not ok or type(branches) ~= "table" then
		return nil, nil, "could not obtain TAStudio branches"
	end
	local index0 = branch_user_number - 1
	local branch = branches[index0]
	if branch == nil then
		return nil, nil, string.format("TAStudio branch #%d does not exist", branch_user_number)
	end
	local frame = tonumber(branch.Frame)
	if frame == nil then
		return nil, nil, string.format("could not determine frame for branch #%d", branch_user_number)
	end
	return index0, math.floor(frame), nil
end

local function reset_to_branch(branch_user_number)
	client.pause()
	local index0, frame, why = get_branch_info(branch_user_number)
	if index0 == nil then error(why) end
	tastudio.loadbranch(index0)
	tastudio.setplayback(frame)
	local spins = 0
	while alive and (client.isseeking() or emu.framecount() ~= frame) do
		emu.yield()
		spins = spins + 1
		if spins > 200000 then
			error(string.format("timed out while loading branch #%d at frame %d", branch_user_number, frame))
		end
	end
	client.pause()
	if not alive then error("script window closed") end
	return frame
end

local function measure_completion(branch_user_number, max_elapsed, expected_hole)
	local start_frame = reset_to_branch(branch_user_number)
	local start_hole = read_hole()
	if expected_hole ~= nil and start_hole ~= expected_hole then
		return nil, start_hole, start_frame
	end
	for elapsed = 1, max_elapsed do
		advance_search_frame()
		if read_hole() ~= start_hole then
			client.pause()
			return elapsed, start_hole, start_frame
		end
	end
	client.pause()
	return nil, start_hole, start_frame
end

local function generate_candidates(center_x, center_y, radius, step, include_center)
	local candidates = {}
	local r2 = radius * radius
	local max_k = math.floor(radius / step)
	for ky = -max_k, max_k do
		local oy = ky * step
		for kx = -max_k, max_k do
			local ox = kx * step
			local d2 = ox * ox + oy * oy
			if d2 <= r2 and (include_center or ox ~= 0 or oy ~= 0) then
				local x = center_x + ox
				local y = center_y + oy
				if x >= LEGAL_X_MIN and x <= LEGAL_X_MAX
					and y >= LEGAL_Y_MIN and y <= LEGAL_Y_MAX then
					candidates[#candidates + 1] = {x = x, y = y, ox = ox, oy = oy, d2 = d2,}
				end
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.d2 ~= b.d2 then return a.d2 < b.d2 end
		if a.oy ~= b.oy then return a.oy < b.oy end
		return a.ox < b.ox
	end)
	return candidates
end

local function validate_display_coord(x, y, label)
	if x == nil or y == nil then
		return false, label .. " X and Y must both be integers"
	end
	if x < X_MIN or x > X_MAX then
		return false, string.format("%s X must be %d..%d", label, X_MIN, X_MAX)
	end
	if y < Y_MIN or y > Y_MAX then
		return false, string.format("%s Y must be %d..%d", label, Y_MIN, Y_MAX)
	end
	return true
end

local function candidate_key(x, y)
	return tostring(x) .. "," .. tostring(y)
end

local function set_progress(iteration, done, total, unique_tested, best_elapsed, best_x, best_y, baseline_elapsed, max_test_frames, objective, center_x, center_y)
	if progress_label then
		forms.settext(progress_label, string.format(
			"Iteration %d | center (%d,%d) | %d / %d new candidates (%.1f%%) | %d unique tested",
			iteration, center_x, center_y,
			done, total, total > 0 and (done * 100 / total) or 100,
			unique_tested))
	end

	if best_label then
		if best_elapsed then
			if objective == OBJECTIVE_OPTIMIZE and baseline_elapsed then
				forms.settext(best_label, string.format(
					"Best: X=%d Y=%d | %d frames | %d faster than baseline (%d)",
					best_x, best_y, best_elapsed, baseline_elapsed - best_elapsed, baseline_elapsed))
			else
				forms.settext(best_label, string.format(
					"Best hole-in-one: X=%d Y=%d | %d frames",
					best_x, best_y, best_elapsed))
			end
		else
			forms.settext(best_label, string.format(
				"Best: no hole-in-one found yet | current test limit: %d frames",
				max_test_frames))
		end
	end
end

local function log_progress_milestone(iteration, done, total, unique_tested,
		best_elapsed, best_x, best_y,
		max_test_frames, next_pct)
	if total <= 0 then return next_pct end
	local pct = done * 100 / total
	local bucket = math.floor(pct / 5) * 5
	if bucket >= next_pct then
		if bucket > 100 then bucket = 100 end
		if best_elapsed then
			log(string.format(
				"Iteration %d: %d%% done (%d/%d new candidates; %d unique total). Current best: (%d,%d), %d frames.",
				iteration, bucket, done, total, unique_tested,	best_x, best_y, best_elapsed))
		else
			log(string.format(
				"Iteration %d: %d%% done (%d/%d new candidates; %d unique total). No HIO yet; test limit %d frames.",
				iteration, bucket, done, total, unique_tested,	max_test_frames))
		end
		return bucket + 5
	end
	return next_pct
end

local function start_search()
	if running then
		status("Search is already running.")
		return
	end
	if not tastudio or not tastudio.engaged or not tastudio.engaged() then
		status("TAStudio is not active.")
		return
	end
	local branch_user_number = read_integer(branch_box)
	if not branch_user_number or branch_user_number < 1 then
		status("TAStudio branch # must be an integer >= 1.")
		return
	end
	local branch_index0, branch_frame, branch_why = get_branch_info(branch_user_number)
	if branch_index0 == nil then
		status(branch_why)
		return
	end
	local cur_x, cur_y = read_integer(current_x_box), read_integer(current_y_box)
	local base_x, base_y = read_integer(center_x_box), read_integer(center_y_box)
	local radius, step = read_integer(radius_box), read_integer(step_box)
	local max_test_frames = read_integer(timeout_box)
	local nudge_x, nudge_y = read_integer(nudge_x_box), read_integer(nudge_y_box)
	local strategy = forms.gettext(strategy_box)
	if strategy ~= STRATEGY_FIRST and strategy ~= STRATEGY_BEST then
		strategy = STRATEGY_FIRST
	end
	local objective = forms.gettext(objective_box)
	if objective ~= OBJECTIVE_OPTIMIZE and objective ~= OBJECTIVE_FIND then
		objective = OBJECTIVE_OPTIMIZE
	end
	local ok, why = validate_display_coord(cur_x, cur_y, "Current cursor")
	if not ok then status(why); return end
	ok, why = validate_display_coord(base_x, base_y, "Search center")
	if not ok then status(why); return end
	if base_x < LEGAL_X_MIN or base_x > LEGAL_X_MAX
		or base_y < LEGAL_Y_MIN or base_y > LEGAL_Y_MAX then
		status(string.format(
			"Search center must be inside legal area X=%d..%d, Y=%d..%d",
			LEGAL_X_MIN, LEGAL_X_MAX, LEGAL_Y_MIN, LEGAL_Y_MAX))
		return
	end
	if not radius or radius < 1 then status("Radius must be an integer >= 1."); return end
	if not step or step < 1 then status("Step must be an integer >= 1."); return end
	if not max_test_frames or max_test_frames < 1 then
		status("Max test frames must be an integer >= 1.")
		return
	end
	if nudge_x == nil or nudge_y == nil then status("Nudge X/Y must be signed integers."); return end
	if math.abs(nudge_x) > MAX_POSITION_DELTA or math.abs(nudge_y) > MAX_POSITION_DELTA then
		status("Nudge X/Y must each stay within +/-255.")
		return
	end
	local video_w, video_h = get_video_size()
	if not video_w or not video_h then
		status("Could not determine core video resolution.")
		return
	end
	local first_circle = generate_candidates(
		base_x, base_y, radius, step, objective == OBJECTIVE_FIND)
	if #first_circle == 0 then
		status("Search circle contains no legal candidate points other than the center.")
		return
	end
	local recording_was_on = false
	if tastudio.getrecording and tastudio.setrecording then
		local ok_rec, rec = pcall(function() return tastudio.getrecording() end)
		if ok_rec and rec then
			recording_was_on = true
			tastudio.setrecording(false)
		end
	end
	running = true
	stop_requested = false
	if objective == OBJECTIVE_OPTIMIZE then
		if progress_label then forms.settext(progress_label, "Measuring baseline hole-in-one...") end
		if best_label then forms.settext(best_label, "Best: measuring baseline...") end
		status(string.format(
			"Optimize-HIO search: branch #%d (frame %d), initial center (%d,%d), radius %d, step %d, strategy: %s. Measuring baseline...",
			branch_user_number, branch_frame, base_x, base_y, radius, step, strategy))
	else
		if progress_label then forms.settext(progress_label, "Preparing find-HIO search...") end
		if best_label then forms.settext(best_label, string.format(
				"Best: no hole-in-one found yet | current test limit: %d frames", max_test_frames)) end
		status(string.format(
			"Find-HIO search: branch #%d (frame %d), initial center (%d,%d), radius %d, step %d, strategy: %s, max %d frames/test.",
			branch_user_number, branch_frame, base_x, base_y, radius, step,
			strategy, max_test_frames))
	end

	local best_plan = nil
	local best_x, best_y = base_x, base_y
	local best_elapsed = nil
	local baseline_elapsed = nil
	local start_hole = nil
	local start_frame = branch_frame
	local original_completion_elapsed = nil
	local trial_horizon = nil
	local keep_horizon = nil
	local center_x, center_y = base_x, base_y
	local iteration = 0
	local unique_tested = 0
	local local_optimum_reached = false
	local tested = {}
	if objective == OBJECTIVE_OPTIMIZE then
		tested[candidate_key(base_x, base_y)] = true
	end
	local search_ok, search_error = pcall(function()
		if objective == OBJECTIVE_OPTIMIZE then
			baseline_elapsed, start_hole, start_frame = measure_completion(
				branch_user_number, max_test_frames, nil)
			if not baseline_elapsed then
				error(string.format(
					"baseline on branch #%d did not complete within %d frames (hole value at start: %s). Use 'Find a hole-in-one' if the center is a miss / hole-in-two first shot.",
					branch_user_number, max_test_frames, tostring(start_hole)))
			end
			best_elapsed = baseline_elapsed
			trial_horizon = math.max(baseline_elapsed + SNAPSHOT_TAIL,
				CANDIDATE_INPUT_SPAN + SNAPSHOT_TAIL)
			keep_horizon = trial_horizon
			log(string.format(
				"Baseline: branch #%d, start frame %d, hole value %d, solution (%d,%d), completion in %d frames (absolute frame %d).",
				branch_user_number, start_frame, start_hole,
				base_x, base_y, baseline_elapsed, start_frame + baseline_elapsed))
		else
			original_completion_elapsed, start_hole, start_frame = measure_completion(
				branch_user_number, max_test_frames, nil)

			if original_completion_elapsed then
				log(string.format(
					"Original movie completes the hole in %d frames (possibly using multiple shots). This is used only to determine how much old mouse input to erase; it is NOT treated as a HIO baseline.",
					original_completion_elapsed))
			else
				start_frame = reset_to_branch(branch_user_number)
				start_hole = read_hole()
				log(string.format(
					"Original movie did not complete within %d frames. Final keep-cleanup will therefore use the full test horizon.",
					max_test_frames))
			end
			trial_horizon = math.max(max_test_frames + SNAPSHOT_TAIL, CANDIDATE_INPUT_SPAN + SNAPSHOT_TAIL)
			keep_horizon = math.max(
				(original_completion_elapsed or max_test_frames) + SNAPSHOT_TAIL, CANDIDATE_INPUT_SPAN + SNAPSHOT_TAIL)
			log(string.format(
				"Find-HIO mode: branch #%d, start frame %d, hole value %d. Center (%d,%d) is only the search center; no successful one-shot baseline is required. Each candidate gets up to %d frames until the first HIO is found.",
				branch_user_number, start_frame, start_hole,
				base_x, base_y, max_test_frames))
		end
		local start_axis_x, start_axis_y = get_start_axis_position(start_frame)
		while alive and not stop_requested do
			iteration = iteration + 1
			local include_center = objective == OBJECTIVE_FIND and iteration == 1
			local all_candidates = generate_candidates(
				center_x, center_y, radius, step, include_center)
			local candidates = {}
			for _, c in ipairs(all_candidates) do
				if not tested[candidate_key(c.x, c.y)] then
					candidates[#candidates + 1] = c
				end
			end
			if #candidates == 0 then
				if best_elapsed then
					log(string.format(
						"Iteration %d: center (%d,%d) has no untested legal candidates in this radius. Local HIO optimum reached.",
						iteration, center_x, center_y))
					local_optimum_reached = true
				else
					log(string.format(
						"Iteration %d: center (%d,%d) has no untested legal candidates and no HIO has been found.",
						iteration, center_x, center_y))
				end
				break
			end
			if best_elapsed then
				log(string.format(
					"Iteration %d starting: center (%d,%d), %d new candidates (%d points in full legal circle; %d already known). Best HIO = %d frames.",
					iteration, center_x, center_y, #candidates, #all_candidates,
					#all_candidates - #candidates, best_elapsed))
			else
				log(string.format(
					"Iteration %d starting: center (%d,%d), %d new candidates (%d points in full legal circle; %d already known). No HIO yet; cutoff = %d frames.",
					iteration, center_x, center_y, #candidates, #all_candidates,
					#all_candidates - #candidates, max_test_frames))
			end
			set_progress(iteration, 0, #candidates, unique_tested,
				best_elapsed, best_x, best_y, baseline_elapsed,
				max_test_frames, objective,
				center_x, center_y)

			local iteration_center_x, iteration_center_y = center_x, center_y
			local improved_this_iteration = false
			local iteration_best_x, iteration_best_y = nil, nil
			local iteration_best_elapsed = nil
			local iteration_done = 0
			local next_progress_pct = 5
			for index, c in ipairs(candidates) do
				iteration_done = index
				if stop_requested or not alive then break end
				tested[candidate_key(c.x, c.y)] = true
				unique_tested = unique_tested + 1

				local trial_start = reset_to_branch(branch_user_number)
				if trial_start ~= start_frame then
					error(string.format("branch frame changed unexpectedly (%d -> %d)", start_frame, trial_start))
				end
				local trial_hole = read_hole()
				if trial_hole ~= start_hole then
					error(string.format(
						"hole RAM value at branch start changed unexpectedly (%d -> %d)",
						start_hole, trial_hole))
				end
				local plan = build_candidate_plan(
					start_frame, start_axis_x, start_axis_y,
					cur_x, cur_y, c.x, c.y,
					video_w, video_h,
					nudge_x, nudge_y)
				local test_limit = best_elapsed and (best_elapsed - 1) or max_test_frames
				local press_elapsed = plan.press_frame - start_frame
				local score = nil
				if press_elapsed < test_limit then
					blank_mouse_horizon(start_frame, trial_horizon)
					apply_candidate(plan, start_frame)

					for elapsed = 1, test_limit do
						advance_search_frame()
						if read_hole() ~= start_hole then
							score = elapsed
							break
						end
					end
					client.pause()
				end
				local qualifies = score and (not best_elapsed or score < best_elapsed)
				if qualifies then
					local first_hio = (best_elapsed == nil)
					best_elapsed = score
					best_x, best_y = c.x, c.y
					best_plan = plan
					improved_this_iteration = true
					iteration_best_x, iteration_best_y = c.x, c.y
					iteration_best_elapsed = score
					if first_hio and objective == OBJECTIVE_FIND then
						log(string.format(
							"HOLE-IN-ONE FOUND [iteration %d]: X=%d Y=%d (offset from center %+d,%+d) -> %d frames; completion frame %d. Future candidates must beat this.",
							iteration, c.x, c.y, c.ox, c.oy,
							score, start_frame + score))
					elseif baseline_elapsed then
						log(string.format(
							"IMPROVEMENT [iteration %d]: X=%d Y=%d (offset from center %+d,%+d) -> %d frames, %d faster than baseline; completion frame %d",
							iteration, c.x, c.y, c.ox, c.oy,
							score, baseline_elapsed - score,
							start_frame + score))
					else
						log(string.format(
							"FASTER HIO [iteration %d]: X=%d Y=%d (offset from center %+d,%+d) -> %d frames; completion frame %d",
							iteration, c.x, c.y, c.ox, c.oy,
							score, start_frame + score))
					end
					if strategy == STRATEGY_FIRST then
						center_x, center_y = c.x, c.y
						log(string.format(
							"Iteration %d: qualifying HIO found after %d/%d new candidates. Aborting the current circle and recentering from (%d,%d) to (%d,%d).",
							iteration, index, #candidates,
							iteration_center_x, iteration_center_y,
							center_x, center_y))
					end
				end
				if index == 1 or index % 5 == 0 or qualifies then
					set_progress(iteration, index, #candidates, unique_tested,
						best_elapsed, best_x, best_y, baseline_elapsed,
						max_test_frames, objective,
						iteration_center_x, iteration_center_y)
					emu.yield()
				end
				next_progress_pct = log_progress_milestone(
					iteration, index, #candidates, unique_tested,
					best_elapsed, best_x, best_y,
					max_test_frames, next_progress_pct)
				if improved_this_iteration and strategy == STRATEGY_FIRST then
					break
				end
			end
			if stop_requested or not alive then break end
			if improved_this_iteration then
				if strategy == STRATEGY_BEST then
					center_x, center_y = iteration_best_x, iteration_best_y
					log(string.format(
						"Iteration %d complete: best qualifying HIO in the full circle is (%d,%d) at %d frames. Recentering from (%d,%d) and starting a new circle.",
						iteration, center_x, center_y, iteration_best_elapsed,
						iteration_center_x, iteration_center_y))
				end
				set_progress(iteration, iteration_done, #candidates, unique_tested,
					best_elapsed, best_x, best_y, baseline_elapsed,
					max_test_frames, objective,
					center_x, center_y)
			else
				set_progress(iteration, #candidates, #candidates, unique_tested,
					best_elapsed, best_x, best_y, baseline_elapsed,
					max_test_frames, objective,
					iteration_center_x, iteration_center_y)
				if best_elapsed then
					log(string.format(
						"Iteration %d complete: no point in the full radius-%d neighborhood around (%d,%d) beat the current HIO time of %d frames. Local optimum reached.",
						iteration, radius, iteration_center_x, iteration_center_y, best_elapsed))
					local_optimum_reached = true
				else
					log(string.format(
						"Iteration %d complete: no hole-in-one found in the full radius-%d neighborhood around (%d,%d) within %d frames/test.",
						iteration, radius, iteration_center_x, iteration_center_y,
						max_test_frames))
				end
				break
			end
		end
	end)
	local restore_ok, restore_error = pcall(function()
		reset_to_branch(branch_user_number)
	end)
	local kept_best = false
	if search_ok and restore_ok and best_plan
		and keep_best_box and forms.ischecked(keep_best_box) then
		local keep_ok, keep_error = pcall(function()
			reset_to_branch(branch_user_number)
			blank_mouse_horizon(start_frame, keep_horizon)
			apply_candidate(best_plan, start_frame)
			tastudio.setplayback(start_frame)
			kept_best = true
		end)
		if not keep_ok then
			search_ok = false
			search_error = "failed to write best candidate: " .. tostring(keep_error)
		end
	end
	running = false
	if recording_was_on and tastudio.setrecording then
		pcall(function() tastudio.setrecording(true) end)
	end
	if not restore_ok then
		status("ERROR restoring base branch: " .. tostring(restore_error))
		return
	end
	if not search_ok then
		status("Search aborted with error: " .. tostring(search_error))
		return
	end
	if stop_requested then
		if best_plan then
			if baseline_elapsed then
				status(string.format(
					"Stopped during iteration %d after %d unique candidates. Best found: (%d,%d), %d frames (%d faster than baseline). %s",
					iteration, unique_tested,
					best_x, best_y, best_elapsed, baseline_elapsed - best_elapsed,
					kept_best and "Best input kept in TAStudio." or "Base branch restored."))
			else
				status(string.format(
					"Stopped during iteration %d after %d unique candidates. Best HIO found: (%d,%d), %d frames. %s",
					iteration, unique_tested,
					best_x, best_y, best_elapsed,
					kept_best and "Best HIO kept in TAStudio." or "Base branch restored."))
			end
		else
			status(string.format(
				"Stopped during iteration %d after %d unique candidates. No hole-in-one found; base branch restored.",
				iteration, unique_tested))
		end
		return
	end
	if objective == OBJECTIVE_OPTIMIZE then
		if best_plan then
			status(string.format(
				"%s Best local solution: (%d,%d), %d frames, %d faster than baseline %d. %d unique candidates tested across %d iteration(s). %s",
				local_optimum_reached and "Local optimum reached." or "Search finished.",
				best_x, best_y, best_elapsed, baseline_elapsed - best_elapsed,
				baseline_elapsed, unique_tested, iteration,
				kept_best and "Best input written to TAStudio." or "Base branch restored."))
		else
			status(string.format(
				"Local optimum is the original solution (%d,%d): %d frames. %d unique candidates tested in %d iteration(s); base branch restored.",
				base_x, base_y, baseline_elapsed, unique_tested, iteration))
		end
	else
		if best_plan then
			status(string.format(
				"%s Best hole-in-one: (%d,%d), %d frames. %d unique candidates tested across %d iteration(s). %s",
				local_optimum_reached and "Local HIO optimum reached." or "Search finished.",
				best_x, best_y, best_elapsed, unique_tested, iteration,
				kept_best and "Best HIO written to TAStudio." or "Base branch restored."))
		else
			status(string.format(
				"No hole-in-one found within the searched radius-%d neighborhood around (%d,%d) using a %d-frame test limit. %d unique candidates tested; base branch restored.",
				radius, base_x, base_y, max_test_frames, unique_tested))
		end
	end
end

local function request_start()
	if running then
		status("Search is already running.")
		return
	end
	start_requested = true
	status("Search queued; starting from the Lua main loop...")
end

local function request_stop()
	if running then
		stop_requested = true
		status("Stop requested; finishing the current candidate...")
	else
		status("No search is running.")
	end
end

-- create form

form = forms.newform(510, 435, "Minigolf iterative local optimizer v2", function()
	stop_requested = true
	alive = false
end)

forms.label(form, "Assumes DOSBox-X Mouse Relative Sensitivity = 1.0", 10, 10, 650, 20)

forms.label(form, "TAStudio branch", 10, 40, 100, 20)
forms.label(form, "#:", 110, 40, 20, 20)
branch_box = forms.textbox(form, "1", 55, 22, nil, 130, 36)

forms.label(form, "(Use View > Display Input coordinates at the branch frame; recording mode must be enabled.)", 10, 75, 650, 20)

forms.label(form, "Current cursor", 10, 110, 100, 20)
forms.label(form, "X:", 110, 110, 20, 20)
current_x_box = forms.textbox(form, "", 70, 22, nil, 130, 107)
forms.label(form, "Y:", 210, 110, 20, 20)
current_y_box = forms.textbox(form, "", 70, 22, nil, 230, 107)

forms.label(form, "Search center", 10, 143, 100, 20)
forms.label(form, "X:", 110, 143, 20, 20)
center_x_box = forms.textbox(form, "", 70, 22, nil, 130, 140)
forms.label(form, "Y:", 210, 143, 20, 20)
center_y_box = forms.textbox(form, "", 70, 22, nil, 230, 140)

forms.label(form, "Radius:", 10, 178, 55, 20)
radius_box = forms.textbox(form, "40", 60, 22, nil, 65, 175)
forms.label(form, "Step:", 145, 178, 45, 20)
step_box = forms.textbox(form, "4", 55, 22, nil, 190, 175)
forms.label(form, "Max test frames:", 270, 178, 85, 20)
timeout_box = forms.textbox(form, "300", 65, 22, nil, 355, 175)
forms.label(form, "frames", 425, 178, 50, 20)

forms.label(form, "Click nudge", 10, 213, 80, 20)
forms.label(form, "X:", 95, 213, 20, 20)
nudge_x_box = forms.textbox(form, "0", 55, 22, nil, 115, 210)
forms.label(form, "Y:", 180, 213, 20, 20)
nudge_y_box = forms.textbox(form, "1", 55, 22, nil, 200, 210)

keep_best_box = forms.checkbox(form, "Keep best input", 285, 213)
forms.setproperty(keep_best_box, "Checked", true)

forms.label(form, "Objective:", 10, 248, 70, 20)
objective_box = forms.dropdown(form, { OBJECTIVE_OPTIMIZE, OBJECTIVE_FIND }, 80, 245, 280, 24)
forms.settext(objective_box, OBJECTIVE_OPTIMIZE)

forms.label(form, "Recenter strategy:", 10, 278, 105, 20)
strategy_box = forms.dropdown(form, { STRATEGY_FIRST, STRATEGY_BEST }, 115, 275, 235, 24)
forms.settext(strategy_box, STRATEGY_FIRST)

forms.label(form,
	string.format("Legal target area: X=%d..%d, Y=%d..%d | Hole u8: %s 0x%08X",
		LEGAL_X_MIN, LEGAL_X_MAX, LEGAL_Y_MIN, LEGAL_Y_MAX,
		HOLE_DOMAIN, HOLE_ADDRESS),
	10, 308, 640, 20)

forms.button(form, "Start local search", request_start, 10, 333, 155, 32)
forms.button(form, "Stop after current test", request_stop, 180, 333, 170, 32)

progress_label = forms.label(form, "Not running.", 10, 375, 645, 22)
best_label = forms.label(form, "Best: not measured yet.", 10, 403, 645, 40)

event.onexit(function()
	stop_requested = true
	if form then pcall(function() forms.destroy(form) end) end
end, "Minigolf local optimizer cleanup")

while alive do
	if start_requested and not running then
		start_requested = false
		start_search()
	end
	emu.yield()
end
