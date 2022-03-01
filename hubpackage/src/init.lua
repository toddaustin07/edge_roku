--[[
  Copyright 2021 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.
  
  DESCRIPTION
  
  SmartThings Edge driver to support Roku devices - both sticks and TVs
  
  This driver is still in development; Edge platform beta socket bugs persist which render this driver unreliable as of 11/3/21

  Currently known issues:
    - tV capability not displaying
    - Fast forward button not working
    - Selection lists in random order
    
  To Dos:
    - Comments
    - Re-factoring of functions (handlers especially)
    - Grouping same-category functions into separate Lua files

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"      --non blocking calls
--local http = require "socket.http"
http.TIMEOUT = 3
local ltn12 = require "ltn12"
local log = require "log"

-- Additional libraries
local xml2lua = require "xml2lua"
local xml_handler = require "xmlhandler.tree"
local Thread = require "st.thread"

-- UPnP library
local upnp = require "UPnP"        

local TARGETDEVICESEARCH = "roku:ecp"

-- Custom Capabilities
local cap_power = capabilities["partyvoice23922.rokupower"]
local cap_keypress = capabilities["partyvoice23922.rokukeys"]
local cap_tvkeypress = capabilities["partyvoice23922.rokutvkeys"]
local cap_mediastat = capabilities["partyvoice23922.rokumediastatus"]
local cap_currapp = capabilities["partyvoice23922.rokucurrentapp"]

-- Profiles for TV vs non-TV devices

local profiles = {
  ["isTV"] = "rokuTV.v1.1",
  ["notTV"] = "rokustick.v1.2",  
  --["notTV"] = "rokuTV.v1.1",      -- debugging
}

-- Temp UPnP metadata storage for newly created devices
local newly_added = {}

-- Other Global variables
local rokuDriver
local rediscovery_thread
local lastinfochange = socket.gettime()
local rokudevinfo = {}
local mediabuttonpressed = {}
local polling_freq = {}
local last_command = {}
local rediscover_timer
local unfoundlist = {}
local applists = {}
local failcount = {}
local devicestates = {}
local tv_channel = 1
local tv_volume = 0

------------------------------------------------------------------------

local schedule_periodic_refresh                    -- forward reference

-- Send HTTP requests to Roku devices
local function send_command(req_method, addr, command, device)

  local responsechunks = {}
  
  local body, code, headers, status
  
  -- log.info(string.format('Sending %s %s to %s', req_method, command, addr))
  
   body, code, headers, status = http.request{
    method = req_method,
    url = 'http://' .. addr .. command,
    sink = ltn12.sink.table(responsechunks)
   }

  local response = table.concat(responsechunks)
  
  --log.info(string.format("response code=<%s>, status=<%s>", code, status))
  
  local returnstatus = 'unknown'
  
  if code ~= nil then

    if string.find(code, "closed") then
      log.warn ("Socket closed unexpectedly")
      returnstatus = string.format("No response")
    elseif string.find(code, "refused") then
      log.warn("Connection refused: ", addr)
      returnstatus = "Refused"
    elseif string.find(code, "timeout") then
      log.warn("HTTP request timed out: ", addr)
      returnstatus = "Timeout"
    elseif code ~= 200 then
      log.warn (string.format("HTTP %s request to %s failed with code %s, status: %s", req_method, addr, tostring(code), status))
      if type(code) == 'number' then
        returnstatus = string.format('HTTP error %s', tostring(code))
      else
        returnstatus = 'Failed'
      end
      
    else
      if device then
        last_command[device.id] = socket.gettime()
        polling_freq[device.id] = 3
        schedule_periodic_refresh(device, polling_freq[device.id])
      end
      return true, response
      
    end
  end

  return false, returnstatus

end


-- Send GET requests (query-type requests) that return XML data
local function get_info(addr, command)

  success, response = send_command('GET', addr, command, nil)

  if success then

    local handler = xml_handler:new()
    local xml_parser = xml2lua.parser(handler)

    xml_parser:parse(response)
    
    if not handler.root then
      log.error ("Response XML parse error - no root")
      return nil
    end

    local parsed_xml = handler.root
  
    return (parsed_xml)
    
  else
    log.warn ('Failed to get info from', addr)
  end

  return nil

end


-- Return true if device is online, false if not
local function is_online(device)

  local upnpdev = device:get_field('upnpdevice')
  if upnpdev then
    if upnpdev.online then
      return true
    end  
  end
  
  return false

end

  
-- Main function to refresh all Roku device states (power, media, app)
local function refresh_all(device)
  
  local upnpdev = device:get_field('upnpdevice')
  local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)
  
  log.info (string.format('Updating %s...', device.label))
  
  -- Get device status to check power
  
  local devicestatus = get_info(lanaddr, '/query/device-info')
  if devicestatus then

    if upnpdev.online == false then
      device:online()
      upnpdev.online = true
      failcount[device.id] = 0 
      polling_freq[device.id] = device.preferences.freq
    end
    
    local powerstat = devicestatus['device-info']['power-mode']
    log.info (string.format('\tPower status: %s', powerstat))
    
    local lastvalue = devicestates[device.id]['power']
    if powerstat ~= lastvalue then
      devicestates[device.id]['power'] = powerstat
      
      if powerstat == 'PowerOn' then
        device:emit_event(cap_power.powerSwitch('On'))
      else
        device:emit_event(cap_power.powerSwitch('Off'))
      end
    end
  else
    failcount[device.id] = failcount[device.id] + 1
    if failcount[device.id] == 3 then
      device:offline()
      upnpdev.online = false
    end
    log.info ('No reponse from Roku; failure count =', failcount[device.id])
    return
    
  end
  
  -- Get Media player state
  
  local mediastatus = get_info(lanaddr, '/query/media-player')
  if mediastatus then
    local mediastate = mediastatus.player._attr.state
    log.info (string.format('\tMedia player state: %s', mediastate))
    
    local lastvalue = devicestates[device.id]['mediaplayer']
    if (mediastate ~= lastvalue) or mediabuttonpressed[device.id] then
      devicestates[device.id]['mediaplayer'] = mediastate
    
      device:emit_event(cap_mediastat.mediaStatus(mediastate))
      
      local convert = {
                        ['play'] = 'playing',
                        ['pause'] = 'paused',
                        ['buffer'] = 'paused',
                        ['stop'] = 'stopped',
                        ['none'] = 'stopped',
                        ['close'] = 'stopped',
                        ['startup'] = 'stopped',
                        ['open'] = 'stopped'
                      }
      local capstatus = convert[mediastate]
      if capstatus then
        device:emit_event(capabilities.mediaPlayback.playbackStatus(capstatus))
      else
        log.error ('Unknown Roku Media Player state encountered:', mediastate)
      end
      mediabuttonpressed[device.id] = false
    end
  else
    log.error ('Failed to get media player status')
    device:emit_event(cap_mediastat.mediaStatus(' '))
    devicestates[device.id]['mediaplayer'] = ' '
  end
  
  -- Get Active App
  
  local appstatus = get_info(lanaddr, '/query/active-app')
  if appstatus then
    local activeapp
    if type(appstatus['active-app'].app) == 'table' then 
      activeapp = appstatus['active-app'].app[1]
    else
      activeapp = appstatus['active-app'].app
    end
    log.info (string.format('\tActive App: %s', activeapp))
    
    local lastvalue = devicestates[device.id]['activeapp']
    if activeapp ~= lastvalue then
      devicestates[device.id]['activeapp'] = activeapp
      device:emit_event(cap_currapp.currentApp(activeapp))
    end
  else
    log.error ('Failed to get active app')
    device:emit_event(cap_currapp.currentApp(' '))
    devicestates[device.id]['activeapp'] = ' '
  end
end


local periodic_refresh                          -- forward reference


schedule_periodic_refresh = function(device, interval)

  local refreshtimer = device:get_field('refreshtimer')
  if refreshtimer then; rokuDriver:cancel_timer(refreshtimer); end
  refreshtimer = device.thread:call_with_delay(interval, periodic_refresh, "Refresh timer")
  device:set_field('refreshtimer', refreshtimer)
  device:set_field('lastrefresh', socket.gettime())
  log.debug (string.format('%s refresh scheduled in %d seconds', device.label, interval))

end

local schedule_rediscover                       -- forward reference
        
-- Called via timer to run periodic refreshes
periodic_refresh = function()

  log.info('Running periodic refresh')

  local device_list = rokuDriver:get_devices()
  local timenow = socket.gettime()
  
  for _, device in ipairs(device_list) do

    if polling_freq[device.id] ~= nil then        -- make sure device has been discovered & initialized
      local timesincelastrefresh = timenow - device:get_field('lastrefresh')
      --log.debug (string.format('Seconds since %s last refresh: %s', device.label, timesincelastrefresh))

      if timesincelastrefresh > polling_freq[device.id] then
        refresh_all(device)
        
        if (is_online(device)) and (failcount[device.id] < 3) then
          
          if (timenow - last_command[device.id]) > 7 then
            polling_freq[device.id] = device.preferences.freq
          end
          
          schedule_periodic_refresh(device, polling_freq[device.id])
        
        -- Device not responding; schedule for periodic rediscovery (could have changed IP addresses)  
        else
          schedule_rediscover(device, 20)
          polling_freq[device.id] = nil
        end
      end
    end
  end
end


-- Initialize periodic refresh timer according to interval preference
local function init_periodic_refresh(device)

  polling_freq[device.id] = device.preferences.freq
  schedule_periodic_refresh(device, device.preferences.freq)

end

-- Callback to handle UPnP device status & config changes; invoked by the UPnP library device monitor 
-- ** Not used in latest code since UPnP device monitoring not enabled **
local function status_changed_callback(device)
  
  -- 1.Examine upnp device metadata for important changes (online/offline status, bootid, configid, etc)
  
  local upnpdev = device:get_field("upnpdevice")
  
  if upnpdev.online then
  
    log.info ("Device is back online")
    device:online()
    refresh_all(device)
    init_periodic_refresh(device)
    
  else
    log.info ("Roku Device has gone offline")
    
    -- Cancel periodic refreshes
    
    local refreshtimer = device:get_field('refreshtimer')
    if refreshtimer then; rokuDriver:cancel_timer(refreshtimer); end
    
    device:offline()
    
  end
end
  
-- Here is where we perform all our device startup tasks
local function startup_device(device, upnpdev)

  upnpdev:init(rokuDriver, device)

  -- upnpdev:monitor(status_changed_callback)       -- no UPnP monitoring for now to minimize LAN calls
  
  device:online()
  upnpdev.online = true
  
  failcount[device.id] = 0
  last_command[device.id] = socket.gettime() - 10
  devicestates[device.id] = {}
  mediabuttonpressed[device.id] = false


  -- Get initial device states
  refresh_all(device)
  
  -- Setup periodic refresh timer

  init_periodic_refresh(device)

  -- Initialize Roku App list
  
  if not applists[device.id] then
    local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)
    local rokuapplist = get_info(lanaddr, '/query/apps')
    if rokuapplist then
      applists[device.id] = {}
      for key, value in ipairs(rokuapplist.apps.app) do
        local record = { ["id"] = value._attr.id, ["name"] = value[1] }
        table.insert(applists[device.id], record)
      end
      device:emit_event(capabilities.mediaPresets.presets(applists[device.id]))
    end
  end

  -- Initialize other capabilities
  
  device:emit_event(capabilities.mediaPlayback.supportedPlaybackCommands({'pause', 'play', 'rewind', 'fastForward'}))

  log.debug (string.format('Device %s a TV?: %s', device.label, device:get_field('isTV')))
  if device:get_field('isTV') then
    device:emit_event(cap_tvkeypress.rokuTVKey(' '))
  else
    device:emit_event(cap_keypress.rokuKey(' '))
  end
  
end

-- Send media control keypress commands to Roku
local function issue_media_cmd(device, command)

  log.debug ('Issuing command to Roku:', command)
  
  local upnpdev = device:get_field('upnpdevice')
  local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)

  if (command == 'stop') or (command == 'stopped') then
    send_command('POST', lanaddr, '/keypress/play', device)
  
  elseif (command == 'pause') or (command == 'paused') then
    send_command('POST', lanaddr, '/keypress/play', device)
  
  elseif (command == 'play') or (command == 'playing') then
    send_command('POST', lanaddr, '/keypress/play', device)
  
  elseif (command == 'rewind') or (command == 'rewinding') then
    send_command('POST', lanaddr, '/keypress/rev', device)
  
  elseif (command == 'fastForward') or (command == 'fastForwarding') then
    send_command('POST', lanaddr, '/keypress/fwd', device)
  
  end
end


------------------------------------------------------------------------
--	      SMARTTHINGS DEVICE CAPABILITY COMMAND HANDLERS
------------------------------------------------------------------------

-- This function would be called by automations
local function handle_power(driver, device, command)

  log.info ('Power switch command:', command.command)

  if is_online(device) then
    local upnpdev = device:get_field('upnpdevice')
    local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)
    devicestates[device.id]['power'] = ''

    if (command.command == 'powerOff') or (command.command == 'Off')then
      send_command('POST', lanaddr, '/keypress/PowerOff', device)
    
    else
      send_command('POST', lanaddr, '/keypress/PowerOn', device)
    end
  else
    device:emit_event(cap_power.powerSwitch((command.command == 'On') and 'Off' or 'On'))
  end
end

-- This function would be called by mobile app interaction
local function handle_setpower(driver, device, command)

  log.info ('SET Power switch command:', command.command, command.args.state)

  if is_online(device) then
    local upnpdev = device:get_field('upnpdevice')
    local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)
    devicestates[device.id]['power'] = ''

    device:emit_event(cap_power.powerSwitch(command.args.state))

    if (command.args.state == 'Off') then
      send_command('POST', lanaddr, '/keypress/PowerOff', device)
    
    else
      send_command('POST', lanaddr, '/keypress/PowerOn', device)
    end
  else
    device:emit_event(cap_power.powerSwitch((command.args.state == 'On') and 'Off' or 'On'))
  end
end

local function handle_selectkey(driver, device, command)
  
  log.info ('Key press selection:', command.args.value)
  device:emit_event(cap_keypress.rokuKey(command.args.value))
  
  if is_online(device) then
    local upnpdev = device:get_field('upnpdevice')
    local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)

    send_command('POST', lanaddr, '/keypress/' .. command.args.value, device)
    device.thread:call_with_delay(2, function() device:emit_event(cap_keypress.rokuKey(' ')); end, 'clear keysel')
      
  else
    device:emit_event(cap_keypress.rokuKey(' ')) 
  end
  
end

function handle_selecttvkey (driver, device, command)

  log.info ('TV Key press selection:', command.args.value)
  device:emit_event(cap_tvkeypress.rokuTVKey(command.args.value))
  
  if is_online(device) then
    local upnpdev = device:get_field('upnpdevice')
    local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)

    send_command('POST', lanaddr, '/keypress/' .. command.args.value, device)
    device.thread:call_with_delay(2, function() device:emit_event(cap_tvkeypress.rokuTVKey(' ')); end, 'clear tvkeysel')
      
  else
    device:emit_event(cap_tvkeypress.rokuTVKey(' ')) 
  end

end

local function handle_preset(driver, device, command)
  
  log.info ('Media Preset action:', command.command, command.args.presetId)
  
  if is_online(device) then
    local upnpdev = device:get_field('upnpdevice')
    local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)
    send_command('POST', lanaddr, '/launch/' .. tostring(command.args.presetId), device)
  end
end


local function handle_setmedia(driver, device, command)

  log.info ('Media Playback setPlaybackStatus command:', command.command, command.args.status)

  if is_online(device) then
    device:emit_event(capabilities.mediaPlayback.playbackStatus(command.args.status))
    local upnpdev = device:get_field('upnpdevice')
    issue_media_cmd(device, command.args.status)
  else
    device:emit_event(capabilities.mediaPlayback.playbackStatus('stopped'))
  end
end

local function handle_mediacmd(driver, device, command)

  log.info ('Media Playback command:', command.command)
  
  local media_status = {
                          ['fastForward'] = 'fast forwarding',
                          ['pause'] = 'paused',
                          ['play'] = 'playing',
                          ['rewind'] = 'rewinding',
                          ['stop'] = 'stopped'
                        }

  mediabuttonpressed[device.id] = true

  if is_online(device) then
    device:emit_event(capabilities.mediaPlayback.playbackStatus(media_status[command.command]))
    local upnpdev = device:get_field('upnpdevice')
    issue_media_cmd(device, command.command)
  else
    device:emit_event(capabilities.mediaPlayback.playbackStatus('stopped'))
  end
end


-- Handle TV .. Not yet tested as tV capability not working in SmartThings
-- TODO: How do we synch channel & volume values from Roku??
local function handle_tvcmds (driver, device, command)

  log.info ('TV command:', command.command, command.args.value)
  
  local upnpdev = device:get_field('upnpdevice')
  local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)
  
  if command.command == 'channelUp' then
    if tv_channel < 200 then
      tv_channel = tv_channel + 1
    end
    device:emit_event(capabilities.tV.channel(tv_channel))
    send_command('POST', lanaddr, '/keypress/ChannelUp', device)
    
  elseif command.command == 'channelDown' then
    if tv_channel > 1 then
      tv_channel = tv_channel - 1
    end
    device:emit_event(capabilities.tV.channel(tv_channel))
    send_command('POST', lanaddr, '/keypress/ChannelDown', device)
    
  elseif command.command == 'volumeUp' then
    if tv_volume < 100 then
      tv_volume = tv_volume + 1
    end
    device:emit_event(capabilities.tV.volume(tv_volume))
    send_command('POST', lanaddr, '/keypress/VolumeUp', device)
    
  elseif command.command == 'volumeDown' then
    if tv_volume > 0 then
      tv_volume = tv_volume - 1
    end
    device:emit_event(capabilities.tV.volume(tv_volume))
    send_command('POST', lanaddr, '/keypress/VolumeDown', device)
  end
end


------------------------------------------------------------------------------------------

-- Scheduled re-discover retry routine for unfound devices (stored in unfoundlist table)
local function proc_rediscover()

  if next(unfoundlist) ~= nil then
  
    log.debug ('Running periodic re-discovery process for uninitialized devices:')
    for device_network_id, table in pairs(unfoundlist) do
      log.debug (string.format('\t%s (%s)', device_network_id, table.device.label))
    end
  
    upnp.discover(TARGETDEVICESEARCH, 3,    
                    function (upnpdev)
      
                      for device_network_id, table in pairs(unfoundlist) do
                        
                        if device_network_id == upnpdev.description.device.UDN:match('^uuid:(.+)') then
                        
                          local device = table.device
                          local callback = table.callback
                          
                          log.info (string.format('Known device <%s (%s)> re-discovered at %s', device.id, device.label, upnpdev.ip))
                          
                          unfoundlist[device_network_id] = nil
                          callback(device, upnpdev)
                        end
                      end
                    end,
                  true,       -- nonstrict
                  false       -- reset
    )
  
     -- give discovery some time to finish
    socket.sleep(15)
    -- Reschedule this routine again if still unfound devices
    if next(unfoundlist) ~= nil then
      rediscover_timer = rediscovery_thread:call_with_delay(30, proc_rediscover, 're-discover routine')
    else
      rediscovery_thread:close()
    end
  end
end


schedule_rediscover = function(device, delay)
  
  if next(unfoundlist) == nil then
    unfoundlist[device.device_network_id] = { ['device'] = device, ['callback'] = startup_device }
    log.warn ('\tScheduling re-discover routine for later')
    if not rediscovery_thread then
      rediscovery_thread = Thread.Thread(rokuDriver, 'rediscover thread')
    end
    rediscover_timer = rediscovery_thread:call_with_delay(delay, proc_rediscover, 're-discover routine')
  else
    unfoundlist[device.device_network_id] = { ['device'] = device, ['callback'] = startup_device }
  end

end


------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.debug(string.format("INIT handler for: <%s (%s)>", device.id, device.label))

  -- retrieve UPnP device metadata if it exists
  local upnpdev = device:get_field("upnpdevice")
  
  if upnpdev == nil then                    -- if nil, then this handler was called to initialize an existing device (eg driver reinstall)
    device:offline()

    -- Store device in unfoundlist table and schedule re-discovery routine
    schedule_rediscover(device, 5)
    
  end
end


-- Called when device is initially discovered and created in SmartThings
local function device_added (driver, device)

  local id = device.device_network_id

  -- get UPnP metadata that was squirreled away when device was created
  upnpdev = newly_added[id]
  newly_added[id] = nil     -- we're done with it
  
  -- store TV indicator
  local isTV = rokudevinfo[device.device_network_id]['is-tv']
  if isTV == 'true' then; isTV = true; else isTV = false; end
  device:set_field('isTV', isTV, { ['persist'] = true })
  
  -- Perform startup tasks
  startup_device(device, upnpdev)
  
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

	-- determined by developer

end


-- Called when device transferred in from another Driver
local function driver_switched(driver, device)

  log.info ('Device received from another driver')

end


-- Called when device was deleted
local function device_removed(_, device)
  
  log.info("<" .. device.id .. "> removed")
  
  local upnpdev = device:get_field("upnpdevice")
  
	-- stop monitoring & allow for later re-discovery 
	upnpdev:forget()                                                    
    
end


-- Take any needed action when device information has changed
local function handler_infochanged(driver, device, event, args)

  log.debug ('Info changed invoked')
  local timenow = socket.gettime()
 
  --[[
  local timesincelast = timenow - lastinfochange

  log.debug('Time since last info_changed:', timesincelast)
  
  lastinfochange = timenow
  
  if (timesincelast > 5) then
  --]]
  
    -- Did preferences change?
  if args.old_st_store.preferences then
  
    if args.old_st_store.preferences.freq ~= device.preferences.freq then
      log.info ('Refresh interval changed to: ', device.preferences.freq)
      init_periodic_refresh(device)
      
    else
    
      -- Assume driver is restarting - shutdown everything
      log.debug ('****** DRIVER RESTART ASSUMED ******')
    
      local refreshtimer = device:get_field('refreshtimer')
      if refreshtimer then; driver:cancel_timer(refreshtimer); end
      log.debug ('\tRefresh timer cancelled for ', device.label)
      
      if rediscover_timer then; driver:cancel_timer(rediscover_timer); end
        
      --local upnpdev = device:get_field('upnpdevice')
      --upnpdev:unregister()
      --upnp.reset(driver)
    end
  end
  --end
end


-- If the hub's IP address changes, this handler is called
local function lan_info_changed_handler(driver, hub_ipv4)

  if driver.listen_ip == nil or hub_ipv4 ~= driver.listen_ip then
  
		-- reset device monitoring and subscription event server            -- THIS NEEDS MORE WORK
    upnp.reset(driver)
  end
end


-- Perform SSDP discovery to find target device(s) on the LAN
local function discovery_handler(driver, _, should_continue)
  
  local known_devices = {}
  local found_devices = {}

  local device_list = driver:get_devices()
  for _, device in ipairs(device_list) do
    local id = device.device_network_id
    known_devices[id] = true
  end

  local repeat_count = 3
  local searchtarget = TARGETDEVICESEARCH
  local waittime = 3                          -- allow LAN devices 3 seconds to respond to discovery requests
  local resetflag = true

  -- We'll limit our discovery to repeat_count to minimize unnecessary LAN traffic

  while should_continue and (repeat_count > 0) do
    log.debug("Making discovery request #" .. ((repeat_count*-1)+4) .. '; for target: ' .. searchtarget)
    
    --****************************************************************************
    upnp.discover(searchtarget, waittime,    
                  function (upnpdev)
    
                    local id = upnpdev.description.device.UDN:match('^uuid:(.+)')
                    local lanaddr = upnpdev.ip .. ':' .. tostring(upnpdev.port)
                    local modelnumber
                    local name
                    local isTV

                    if not known_devices[id] and not found_devices[id] then
                      found_devices[id] = true

                      -- Get device-info from Roku:
                      --   This enables us to determine if it's a TV, and 
                      --   Create a device label that includes its friendly name & location

                      local devinfo = get_info(lanaddr, '/query/device-info')
                      
                      if devinfo then
                        
                        rokudevinfo[id] = devinfo['device-info']
                        isTV = rokudevinfo[id]['is-tv']
                        modelnumber = rokudevinfo[id]['model-number']
                        name = rokudevinfo[id]['friendly-model-name'] .. ' - ' .. rokudevinfo[id]['user-device-location']
                        
                      else
                        log.warn ('Roku device info not available; using UPnP description for new device metadata')
                        modelnumber = upnpdev.description.device.modelName
                        name = upnpdev.description.device.friendlyName
                      end
                      
                      local devprofile
                      log.debug ('isTV =', isTV)
                      if isTV == 'true' then  
                        devprofile = profiles['isTV']
                      elseif isTV == 'false' then
                        devprofile = profiles['notTV']
                      else
                        log.error("Unexpected value of 'is-tv' field in Roku device info")
                      end
                      
                      log.debug ('Using profile:', devprofile)

                      if devprofile then                

                        local create_device_msg = {
                          type = "LAN",
                          device_network_id = id,
                          label = name,
                          profile = devprofile,
                          manufacturer = upnpdev.description.device.manufacturer,
                          model = modelnumber,
                          vendor_provided_label = name,
                        }
                        
                        log.info(string.format("Creating discovered device: %s / %s at %s", name, modelnumber, lanaddr))
                        log.info("\tUPnP UDN == device_network_id = ", id)

												-- squirrel away UPnP device metadata for device_added handler
												--   > because there's currently no way to attach it to the new device here :-(
                        newly_added[id] = upnpdev
                        
                        -- create the device
                        assert (driver:try_create_device(create_device_msg), "failed to create device record")

                      else
                        log.warn(string.format("Discovered device not recognized (name: %s / model: %s)", name, modelnumber))
                      end
                    else
                      log.debug("Discovered device was already known")
                    end
                  end,
                true,       -- nonstrict
                resetflag   -- reset
    )
    --***************************************************************************
    resetflag = false
    repeat_count = repeat_count - 1
    if repeat_count > 0 then
      socket.sleep(2)                          -- avoid creating network storms
    end
  end
  log.info("Driver is exiting discovery")
end

-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
rokuDriver = Driver("rokuDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = handler_infochanged,
    driverSwitched = driver_switched,
    doConfigure = device_doconfigure,
    deleted = device_removed,
    removed = device_removed,
  },
  lan_info_changed_handler = lan_info_changed_handler,
  capability_handlers = {
  
    [cap_power.ID] = {
      [cap_power.commands.powerOn.NAME] = handle_power,
      [cap_power.commands.powerOff.NAME] = handle_power,
      [cap_power.commands.setPower.NAME] = handle_setpower
    },
    [cap_keypress.ID] = {
      [cap_keypress.commands.selectKey.NAME] = handle_selectkey,
    },
    [cap_tvkeypress.ID] = {
      [cap_tvkeypress.commands.selectTVKey.NAME] = handle_selecttvkey,    -- not yet defined; not working
    },
    [capabilities.mediaPresets.ID] = {
      [capabilities.mediaPresets.commands.playPreset.NAME] = handle_preset,
    },
    [capabilities.mediaPlayback.ID] = {
      [capabilities.mediaPlayback.commands.setPlaybackStatus.NAME] = handle_setmedia,
      [capabilities.mediaPlayback.commands.fastForward.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.pause.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.play.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.rewind.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.stop.NAME] = handle_mediacmd,
    },
    [capabilities.tV.ID] = {
      [capabilities.tV.commands.channelUp.NAME] = handle_tvcmds,
      [capabilities.tV.commands.channelDown.NAME] = handle_tvcmds,
      [capabilities.tV.commands.volumeUp.NAME] = handle_tvcmds,
      [capabilities.tV.commands.volumeDown.NAME] = handle_tvcmds,
    },
  }
})

log.info ('Starting Roku Driver v0.3')

rokuDriver:run()
