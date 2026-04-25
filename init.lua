local mod = {
  name = "Vehicle Price Tuner",
  version = "0.1.0"
}

local DEFAULT_CONFIG = {
  enabled = true,
  showWindow = true,
  applyOnInit = true,
  showUnmappedVehicles = false,
  scanCandidatePriceFields = false,
  generateVanillaTweakFile = true,
  vanillaTweakFilePath = "../../../../../../r6/tweaks/VehiclePriceTuner/vehicle_price_tuner.yaml",
  vcdMultiplier = 1.0,
  vanillaMultiplier = 1.0,
  minPrice = 1000,
  roundTo = 500,
  overrides = {},
  manualVehicles = {},
  candidatePriceFields = {
    "dealerPrice",
    "price",
    "purchasePrice",
    "autofixerPrice",
    "buyPrice"
  }
}

local DEFAULT_STATE = {
  version = 1,
  prices = {}
}

local config = {}
local state = {}
local vanillaManifest = { vehicles = {} }
local vehicles = {}
local vehicleById = {}
local overlayOpen = false
local filesLoaded = false
local autoApplied = false
local writeFailureSamples = 0
local updateTimer = 0
local retryCount = 0
local lastVcdCacheCount = -1
local ui = {
  search = "",
  filter = 1,
  selectedId = "",
  selectedPriceText = "",
  selectedFlatText = "",
  newVehicleId = "",
  newVehicleName = "",
  newVehicleFlat = "",
  message = ""
}

local FILTERS = {
  "All",
  "VCD/Modded",
  "Vanilla",
  "Manual",
  "Changed",
  "Unmapped"
}

local function log(message)
  local text = ("[%s] %s"):format(mod.name, tostring(message))
  print(text)
  if spdlog and spdlog.info then
    pcall(function() spdlog.info(text) end)
  end
end

local function copyDefaults(target, defaults)
  target = target or {}
  for key, value in pairs(defaults) do
    if target[key] == nil then
      if type(value) == "table" then
        target[key] = copyDefaults({}, value)
      else
        target[key] = value
      end
    elseif type(value) == "table" and type(target[key]) == "table" then
      copyDefaults(target[key], value)
    end
  end
  return target
end

local function tableCount(value)
  local count = 0
  if type(value) ~= "table" then
    return count
  end

  for _ in pairs(value) do
    count = count + 1
  end
  return count
end

local function readText(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()
  if type(content) == "string" then
    content = content:gsub("^\239\187\191", "")
  end
  return content
end

local function writeText(path, content)
  local file = io.open(path, "w")
  if not file then
    log("Could not write " .. path)
    return false
  end

  file:write(content)
  file:close()
  return true
end

local function ensureDirectoryFor(path)
  -- CET disables os.execute. The installer/create step owns directory creation.
  return true
end

local function deleteFile(path)
  local ok = os.remove(path)
  return ok == true
end

local function decodeJson(path, fallback)
  if not json or not json.decode then
    log("CET JSON helpers are unavailable; using defaults for " .. path)
    return fallback
  end

  local content = readText(path)
  if not content or content == "" then
    return fallback
  end

  local ok, decoded = pcall(json.decode, content)
  if ok and type(decoded) == "table" then
    return decoded
  end

  log("Could not parse " .. path .. "; using defaults (" .. tostring(decoded) .. ")")
  return fallback
end

local function encodeJson(value)
  if json and json.encode then
    local ok, encoded = pcall(json.encode, value)
    if ok then
      return encoded
    end
  end

  return "{}"
end

local function saveConfig()
  writeText("config.json", encodeJson(config))
end

local function saveState()
  writeText("state.json", encodeJson(state))
end

local function loadFiles()
  config = copyDefaults(decodeJson("config.json", {}), DEFAULT_CONFIG)
  state = copyDefaults(decodeJson("state.json", {}), DEFAULT_STATE)
  vanillaManifest = decodeJson("data/vanilla_vehicles.json", { vehicles = {} })

  config.scanAllVehicleRecords = nil
  if type(config.overrides) ~= "table" then config.overrides = {} end
  if type(config.manualVehicles) ~= "table" then config.manualVehicles = {} end
  if #config.overrides > 0 then config.overrides = {} end
  if #config.manualVehicles > 0 then config.manualVehicles = {} end
  if type(config.vanillaTweakFilePath) ~= "string" or config.vanillaTweakFilePath == "" then
    config.vanillaTweakFilePath = DEFAULT_CONFIG.vanillaTweakFilePath
  end
  if type(state.prices) ~= "table" then state.prices = {} end
  if type(vanillaManifest.vehicles) ~= "table" then vanillaManifest.vehicles = {} end
  filesLoaded = true
end

local function ensureFilesLoaded()
  if not filesLoaded then
    loadFiles()
  end
end

local function toRecordName(value)
  if value == nil then return nil end

  local valueType = type(value)
  if valueType == "string" then
    return value
  end

  if valueType == "table" or valueType == "userdata" then
    local okValue, rawValue = pcall(function() return value.value end)
    if okValue and type(rawValue) == "string" then
      return rawValue
    end

    local okId, rawId = pcall(function()
      if value.GetID then
        return value:GetID()
      end
      return nil
    end)
    if okId and rawId then
      return toRecordName(rawId)
    end
  end

  local text = tostring(value)
  local quoted = text:match("[\"'](Vehicle%.[^\"']+)[\"']")
  if quoted then return quoted end

  local plain = text:match("(Vehicle%.[%w_%.%-]+)")
  if plain then return plain end

  return text
end

local function toTweakDbId(value)
  if TweakDBID and TweakDBID.new then
    local ok, id = pcall(function() return TweakDBID.new(tostring(value)) end)
    if ok and id then
      return id
    end
  end

  return value
end

local function getFlat(flat)
  local ok, value = pcall(function() return TweakDB:GetFlat(flat) end)
  if ok then
    return value
  end

  local flatId = toTweakDbId(flat)
  ok, value = pcall(function() return TweakDB:GetFlat(flatId) end)
  if ok then
    return value
  end

  return nil
end

local function toTypedValue(value)
  if ToVariant then
    local variantType = "Int32"
    if type(value) == "number" and value % 1 ~= 0 then
      variantType = "Float"
    end

    local ok, variant = pcall(function() return ToVariant(value, variantType) end)
    if ok and variant then
      return variant
    end

    ok, variant = pcall(function() return ToVariant(value) end)
    if ok and variant then
      return variant
    end
  end

  return value
end

local function setFlat(flat, value)
  local typedValue = toTypedValue(value)
  local ok, result = pcall(function() return TweakDB:SetFlat(flat, typedValue) end)
  local recordId = tostring(flat):match("^(.*)%.")
  if ok and recordId and TweakDB.Update then
    pcall(function() TweakDB:Update(recordId) end)
  end

  local after = getFlat(flat)
  if ok and tonumber(after) == tonumber(value) then
    return true
  end

  if TweakDB.SetFlatNoUpdate then
    local noUpdateOk = pcall(function() return TweakDB:SetFlatNoUpdate(flat, typedValue) end)
    if noUpdateOk and recordId and TweakDB.Update then
      pcall(function() TweakDB:Update(recordId) end)
    end

    after = getFlat(flat)
    if noUpdateOk and tonumber(after) == tonumber(value) then
      return true
    end
  end

  local flatId = toTweakDbId(flat)
  local idOk, idResult = pcall(function() return TweakDB:SetFlat(flatId, typedValue) end)
  if idOk and recordId and TweakDB.Update then
    pcall(function() TweakDB:Update(toTweakDbId(recordId)) end)
  end

  after = getFlat(flat)
  if idOk and tonumber(after) == tonumber(value) then
    return true
  end

  writeFailureSamples = writeFailureSamples + 1
  if writeFailureSamples <= 12 then
    log(("Write failed for %s: target=%s, after=%s, stringOk=%s, stringResult=%s, idOk=%s, idResult=%s"):format(
      tostring(flat),
      tostring(value),
      tostring(after),
      tostring(ok),
      tostring(result),
      tostring(idOk),
      tostring(idResult)
    ))
  end
  return false
end

local function addCandidate(candidates, id, meta, allowAnyId)
  if not id or id == "" then return end
  if not allowAnyId and not id:match("^Vehicle%.") then return end
  candidates[id] = candidates[id] or {}
  if meta then
    for key, value in pairs(meta) do
      candidates[id][key] = value
    end
  end
end

local function manifestById()
  local result = {}
  for _, entry in ipairs(vanillaManifest.vehicles or {}) do
    if entry.id and entry.id ~= "" then
      result[entry.id] = entry
    end
  end
  return result
end

local function getDisplayName(recordId)
  local displayName = getFlat(recordId .. ".displayName")
  if displayName then
    return tostring(displayName)
  end

  local name = getFlat(recordId .. ".name")
  if name then
    return tostring(name)
  end

  return recordId
end

local function collectVcdVehicles(candidates)
  if not TweakDB.GetRecords then
    return
  end

  local ok, records = pcall(function() return TweakDB:GetRecords("gamedataVehicle_Record") end)
  if not ok or type(records) ~= "table" then
    return
  end

  for _, record in ipairs(records) do
    local id = toRecordName(record)
    if id and id:match("^Vehicle%.") then
      local price = getFlat(id .. ".dealerPrice")
      if type(price) == "number" and price > 0 then
        addCandidate(candidates, id, {
          type = "VCD/Modded",
          displayName = getDisplayName(id),
          priceFlat = id .. ".dealerPrice"
        })
      elseif config.showUnmappedVehicles then
        addCandidate(candidates, id, {
          type = "Unmapped",
          displayName = getDisplayName(id)
        })
      end
    end
  end
end

local function collectVehicleCandidates()
  local candidates = {}
  local vanilla = manifestById()

  for id, entry in pairs(vanilla) do
    addCandidate(candidates, id, {
      type = "Vanilla",
      displayName = entry.name or id,
      priceFlat = entry.priceFlat
    }, true)
  end

  for id, entry in pairs(config.manualVehicles or {}) do
    if type(entry) == "table" then
      addCandidate(candidates, id, {
        type = entry.type or "Manual",
        displayName = entry.name or id,
        priceFlat = entry.priceFlat
      }, true)
    end
  end

  collectVcdVehicles(candidates)

  return candidates
end

local function findPriceFlat(id, meta)
  if meta and meta.priceFlat and meta.priceFlat ~= "" then
    return meta.priceFlat, meta.type or "Manual"
  end

  local manual = config.manualVehicles and config.manualVehicles[id]
  if type(manual) == "table" and manual.priceFlat and manual.priceFlat ~= "" then
    return manual.priceFlat, manual.type or "Manual"
  end

  local dealerFlat = id .. ".dealerPrice"
  if type(getFlat(dealerFlat)) == "number" then
    return dealerFlat, "VCD/Modded"
  end

  if config.scanCandidatePriceFields then
    for _, field in ipairs(config.candidatePriceFields or {}) do
      if field ~= "dealerPrice" then
        local flat = id .. "." .. field
        if type(getFlat(flat)) == "number" then
          return flat, meta and meta.type or "Manual"
        end
      end
    end
  end

  return nil, meta and meta.type or "Unmapped"
end

local function getBasePrice(priceFlat, currentPrice, vehicle)
  local entry = state.prices[priceFlat]
  if type(entry) == "table" then
    local last = tonumber(entry.lastWrittenPrice)
    local base = tonumber(entry.basePrice)
    local staticTarget = tonumber(entry.staticTargetPrice)
    local current = tonumber(currentPrice)
    if base and ((last and current == last) or current == base or (staticTarget and current == staticTarget)) then
      return base
    end
  end

  state.prices[priceFlat] = {
    basePrice = tonumber(currentPrice) or 0,
    lastWrittenPrice = tonumber(currentPrice) or 0,
    vehicleId = vehicle.id,
    displayName = vehicle.displayName,
    type = vehicle.type
  }

  return tonumber(currentPrice) or 0
end

local function roundPrice(value)
  value = tonumber(value) or 0
  local minimum = tonumber(config.minPrice) or 0
  local roundTo = tonumber(config.roundTo) or 0

  if value < minimum then
    value = minimum
  end

  if roundTo > 0 then
    value = math.floor((value / roundTo) + 0.5) * roundTo
  end

  return math.max(0, math.floor(value + 0.5))
end

local function computedPrice(vehicle)
  local override = tonumber(config.overrides[vehicle.id])
  if override then
    return roundPrice(override)
  end

  local multiplier = tonumber(config.vcdMultiplier) or 1.0
  if vehicle.type == "Vanilla" or vehicle.type == "Manual" then
    multiplier = tonumber(config.vanillaMultiplier) or 1.0
  end

  return roundPrice((tonumber(vehicle.basePrice) or 0) * multiplier)
end

local function rememberWrittenPrice(vehicle, newPrice)
  if not vehicle or not vehicle.priceFlat or vehicle.priceFlat == "" then
    return
  end

  state.prices[vehicle.priceFlat] = state.prices[vehicle.priceFlat] or {}
  state.prices[vehicle.priceFlat].basePrice = vehicle.basePrice
  state.prices[vehicle.priceFlat].lastWrittenPrice = newPrice
  state.prices[vehicle.priceFlat].vehicleId = vehicle.id
  state.prices[vehicle.priceFlat].displayName = vehicle.displayName
  state.prices[vehicle.priceFlat].type = vehicle.type
end

local function usesStaticVanillaTweak(vehicle)
  if not vehicle or not vehicle.mapped then
    return false
  end

  if vehicle.type == "Vanilla" then
    return true
  end

  local flat = tostring(vehicle.priceFlat or "")
  return flat:match("^EconomicAssignment%.") ~= nil
end

local function writeVanillaTweakFile()
  if not config.generateVanillaTweakFile then
    deleteFile(config.vanillaTweakFilePath)
    return 0, "disabled"
  end

  local lines = {
    "# Generated by Vehicle Price Tuner.",
    "# Vanilla AutoFixer prices are loaded by TweakXL at game startup.",
    "# Use the CET window to regenerate this file, then restart the game.",
    ""
  }
  local count = 0

  for _, vehicle in ipairs(vehicles) do
    if usesStaticVanillaTweak(vehicle) then
      local newPrice = computedPrice(vehicle)
      table.insert(lines, ("%s: %d"):format(vehicle.priceFlat, newPrice))
      count = count + 1

      rememberWrittenPrice(vehicle, newPrice)
      state.prices[vehicle.priceFlat].staticTargetPrice = newPrice
    end
  end

  if count == 0 then
    deleteFile(config.vanillaTweakFilePath)
    return 0, "no vanilla entries"
  end

  ensureDirectoryFor(config.vanillaTweakFilePath)
  if writeText(config.vanillaTweakFilePath, table.concat(lines, "\n") .. "\n") then
    saveState()
    return count, "written"
  end

  return 0, "write failed"
end

local function getVcdSystem()
  if not Game or not Game.GetScriptableSystemsContainer then
    return nil
  end

  local ok, container = pcall(function() return Game.GetScriptableSystemsContainer() end)
  if not ok or not container then
    return nil
  end

  local okSystem, system = pcall(function()
    return container:Get("CarDealer.System.PurchasableVehicleSystem")
  end)

  if okSystem and system then
    return system
  end

  if CName and CName.new then
    local okCName, cNameSystem = pcall(function()
      return container:Get(CName.new("CarDealer.System.PurchasableVehicleSystem"))
    end)

    if okCName and cNameSystem then
      return cNameSystem
    end
  end

  return nil
end

local function buildVcdVariantMap()
  local result = {}

  for _, vehicle in ipairs(vehicles) do
    if vehicle.type == "VCD/Modded" and vehicle.mapped then
      result[vehicle.id] = vehicle

      local variants = getFlat(vehicle.id .. ".dealerVariants")
      if type(variants) == "table" then
        for _, variant in ipairs(variants) do
          local variantId = toRecordName(variant)
          if variantId and variantId ~= "" then
            result[variantId] = vehicle
          end
        end
      end
    end
  end

  return result
end

local function syncVcdCache()
  local system = getVcdSystem()
  if not system then
    if lastVcdCacheCount ~= -2 then
      log("VCD system not available yet")
      lastVcdCacheCount = -2
    end
    return 0
  end

  local variantMap = buildVcdVariantMap()
  local updated = 0
  local stockType = "nil"

  local ok = pcall(function()
    local stock = system.m_storeVehicles
    if type(stock) ~= "table" and system.GetList then
      local okList, list = pcall(function() return system:GetList() end)
      if okList then
        stock = list
      end
    end

    stockType = type(stock)
    if type(stock) ~= "table" then
      return
    end

    for _, bundle in ipairs(stock) do
      local matchedVehicle = nil
      if type(bundle.variants) == "table" then
        for _, variant in ipairs(bundle.variants) do
          if variant.record then
            local variantId = toRecordName(variant.record:GetID())
            if variantId and variantMap[variantId] then
              matchedVehicle = variantMap[variantId]
              break
            end
          end
        end
      end

      if matchedVehicle then
        bundle.price = computedPrice(matchedVehicle)
        updated = updated + 1
      end
    end
  end)

  if ok then
    if updated ~= lastVcdCacheCount then
      log(("VCD cache sync updated %d entries (stock=%s, mapped=%d)"):format(updated, stockType, tableCount(variantMap)))
      lastVcdCacheCount = updated
    end
    return updated
  end

  log("VCD cache sync failed")
  return 0
end

local function rebuildVehicles()
  vehicles = {}
  vehicleById = {}

  local candidates = collectVehicleCandidates()
  for id, meta in pairs(candidates) do
    local priceFlat, vehicleType = findPriceFlat(id, meta)
    local currentPrice = priceFlat and getFlat(priceFlat) or nil
    local vehicle = {
      id = id,
      displayName = meta.displayName or id,
      type = vehicleType or meta.type or "Unmapped",
      priceFlat = priceFlat or "",
      currentPrice = tonumber(currentPrice),
      basePrice = nil,
      targetPrice = nil,
      mapped = priceFlat ~= nil and type(currentPrice) == "number",
      changed = false
    }

    if vehicle.mapped then
      vehicle.basePrice = getBasePrice(priceFlat, currentPrice, vehicle)
      vehicle.targetPrice = computedPrice(vehicle)
      vehicle.changed = tonumber(vehicle.currentPrice) ~= tonumber(vehicle.targetPrice)
    end

    table.insert(vehicles, vehicle)
    vehicleById[id] = vehicle
  end

  table.sort(vehicles, function(a, b)
    return tostring(a.displayName):lower() < tostring(b.displayName):lower()
  end)

  if ui.selectedId ~= "" and not vehicleById[ui.selectedId] then
    ui.selectedId = ""
  end

  saveState()
end

local function applyVehicle(vehicle, skipCacheSync)
  if not vehicle or not vehicle.mapped then
    return false, "Vehicle has no mapped price flat"
  end

  if usesStaticVanillaTweak(vehicle) and config.generateVanillaTweakFile then
    local count, status = writeVanillaTweakFile()
    if status == "written" then
      return true, ("Wrote vanilla tweak file (%d entries). Restart game to load vanilla AutoFixer prices."):format(count)
    end
    return false, "Failed to write vanilla tweak file: " .. tostring(status)
  end

  local newPrice = computedPrice(vehicle)
  if vehicle.type == "VCD/Modded" then
    rememberWrittenPrice(vehicle, newPrice)
    saveState()
    local cached = 0
    if not skipCacheSync then
      cached = syncVcdCache()
    end
    return true, ("Applied VCD cache price %s = %s; refreshed %d cache entries"):format(vehicle.displayName, tostring(newPrice), cached)
  end

  if setFlat(vehicle.priceFlat, newPrice) then
    rememberWrittenPrice(vehicle, newPrice)
    saveState()
    if not skipCacheSync then
      syncVcdCache()
    end
    return true, "Applied " .. vehicle.displayName .. " = " .. tostring(newPrice)
  end

  return false, "Failed to write " .. vehicle.priceFlat
end

local function applyAll()
  if not config.enabled then
    ui.message = "Mod is disabled"
    return
  end

  writeFailureSamples = 0
  local changed = 0
  local skipped = 0
  local staticCount = 0
  local staticStatus = "not written"
  local staticSkipped = 0
  local vcdRuntime = 0
  for _, vehicle in ipairs(vehicles) do
    if vehicle.mapped then
      if usesStaticVanillaTweak(vehicle) and config.generateVanillaTweakFile then
        staticSkipped = staticSkipped + 1
      elseif vehicle.type == "VCD/Modded" then
        rememberWrittenPrice(vehicle, computedPrice(vehicle))
        vcdRuntime = vcdRuntime + 1
      else
        local ok = applyVehicle(vehicle, true)
        if ok then changed = changed + 1 else skipped = skipped + 1 end
      end
    else
      skipped = skipped + 1
    end
  end

  local cached = syncVcdCache()
  saveState()

  if config.generateVanillaTweakFile then
    local okStatic, countOrError, status = pcall(writeVanillaTweakFile)
    if okStatic then
      staticCount = countOrError
      staticStatus = status
    else
      staticStatus = "write failed: " .. tostring(countOrError)
      log("Vanilla tweak file generation failed: " .. tostring(countOrError))
    end
  end

  rebuildVehicles()
  ui.message = ("Applied %d VCD vehicles and %d manual runtime vehicles, skipped %d, refreshed %d VCD cache entries, vanilla tweak entries %d (%s)"):format(vcdRuntime, changed, skipped + staticSkipped, cached, staticCount, staticStatus)
  log(ui.message)
end

local function resetVehicle(vehicle, skipCacheSync)
  if not vehicle or not vehicle.mapped then
    return false, "Vehicle has no mapped price flat"
  end

  local basePrice = tonumber(vehicle.basePrice)
  if not basePrice then
    return false, "Missing base price"
  end

  if usesStaticVanillaTweak(vehicle) and config.generateVanillaTweakFile then
    config.overrides[vehicle.id] = nil
    state.prices[vehicle.priceFlat] = state.prices[vehicle.priceFlat] or {}
    state.prices[vehicle.priceFlat].lastWrittenPrice = basePrice
    state.prices[vehicle.priceFlat].staticTargetPrice = nil
    deleteFile(config.vanillaTweakFilePath)
    saveConfig()
    saveState()
    return true, "Removed vanilla tweak file. Restart game to restore vanilla AutoFixer base prices."
  end

  if vehicle.type == "VCD/Modded" then
    config.overrides[vehicle.id] = nil
    rememberWrittenPrice(vehicle, basePrice)
    saveConfig()
    saveState()
    if not skipCacheSync then
      syncVcdCache()
    end
    return true, "Reset VCD cache price for " .. vehicle.displayName
  end

  if setFlat(vehicle.priceFlat, basePrice) then
    config.overrides[vehicle.id] = nil
    state.prices[vehicle.priceFlat].lastWrittenPrice = basePrice
    saveConfig()
    saveState()
    if not skipCacheSync then
      syncVcdCache()
    end
    return true, "Reset " .. vehicle.displayName
  end

  return false, "Failed to reset " .. vehicle.priceFlat
end

local function resetAll()
  local reset = 0
  local skipped = 0

  for _, vehicle in ipairs(vehicles) do
    if vehicle.mapped then
      local ok = resetVehicle(vehicle, true)
      if ok then reset = reset + 1 else skipped = skipped + 1 end
    else
      skipped = skipped + 1
    end
  end

  local cached = syncVcdCache()
  rebuildVehicles()
  ui.message = ("Reset %d vehicles, skipped %d, refreshed %d VCD cache entries"):format(reset, skipped, cached)
  log(ui.message)
end

local function exportDetected()
  local output = {
    version = mod.version,
    vehicles = {}
  }

  for _, vehicle in ipairs(vehicles) do
    table.insert(output.vehicles, {
      id = vehicle.id,
      name = vehicle.displayName,
      type = vehicle.type,
      priceFlat = vehicle.priceFlat,
      basePrice = vehicle.basePrice,
      currentPrice = vehicle.currentPrice,
      targetPrice = vehicle.targetPrice,
      mapped = vehicle.mapped
    })
  end

  if writeText("detected_vehicles.json", encodeJson(output)) then
    ui.message = "Exported detected_vehicles.json"
  else
    ui.message = "Failed to export detected_vehicles.json"
  end
end

local function stringContains(haystack, needle)
  if needle == "" then return true end
  haystack = tostring(haystack or ""):lower()
  needle = tostring(needle or ""):lower()
  return haystack:find(needle, 1, true) ~= nil
end

local function passesFilter(vehicle)
  local filter = FILTERS[ui.filter] or "All"
  if filter == "All" then return true end
  if filter == "Changed" then return vehicle.changed end
  if filter == "Unmapped" then return not vehicle.mapped end
  return vehicle.type == filter
end

local function filteredVehicles()
  local result = {}
  for _, vehicle in ipairs(vehicles) do
    if passesFilter(vehicle)
      and (stringContains(vehicle.id, ui.search) or stringContains(vehicle.displayName, ui.search)) then
      table.insert(result, vehicle)
    end
  end
  return result
end

local function drawGlobalControls()
  local oldValue

  oldValue = config.enabled
  config.enabled = ImGui.Checkbox("Enabled", config.enabled)
  if oldValue ~= config.enabled then saveConfig() end

  oldValue = config.applyOnInit
  config.applyOnInit = ImGui.Checkbox("Apply on init", config.applyOnInit)
  if oldValue ~= config.applyOnInit then saveConfig() end

  oldValue = config.showUnmappedVehicles
  config.showUnmappedVehicles = ImGui.Checkbox("Show unmapped debug records", config.showUnmappedVehicles)
  if oldValue ~= config.showUnmappedVehicles then saveConfig(); rebuildVehicles() end

  oldValue = config.scanCandidatePriceFields
  config.scanCandidatePriceFields = ImGui.Checkbox("Scan candidate price fields", config.scanCandidatePriceFields)
  if oldValue ~= config.scanCandidatePriceFields then saveConfig(); rebuildVehicles() end

  oldValue = config.generateVanillaTweakFile
  config.generateVanillaTweakFile = ImGui.Checkbox("Generate vanilla TweakXL file", config.generateVanillaTweakFile)
  if oldValue ~= config.generateVanillaTweakFile then saveConfig() end

  oldValue = config.vcdMultiplier
  config.vcdMultiplier = ImGui.InputFloat("VCD/modded multiplier", config.vcdMultiplier, 0.05, 0.25, "%.2f")
  if oldValue ~= config.vcdMultiplier then saveConfig(); rebuildVehicles() end

  oldValue = config.vanillaMultiplier
  config.vanillaMultiplier = ImGui.InputFloat("Vanilla AutoFixer/manual multiplier", config.vanillaMultiplier, 0.05, 0.25, "%.2f")
  if oldValue ~= config.vanillaMultiplier then saveConfig(); rebuildVehicles() end

  oldValue = config.minPrice
  config.minPrice = ImGui.InputInt("Minimum price", config.minPrice)
  if oldValue ~= config.minPrice then saveConfig(); rebuildVehicles() end

  oldValue = config.roundTo
  config.roundTo = ImGui.InputInt("Round to", config.roundTo)
  if oldValue ~= config.roundTo then saveConfig(); rebuildVehicles() end

  if ImGui.Button("Apply All") then applyAll() end
  ImGui.SameLine()
  if ImGui.Button("Write Vanilla File") then
    local count, status = writeVanillaTweakFile()
    ui.message = ("Vanilla tweak file: %s (%d entries). Restart game to load vanilla prices."):format(status, count)
    log(ui.message)
  end
  ImGui.SameLine()
  if ImGui.Button("Reset All") then resetAll() end
  ImGui.SameLine()
  if ImGui.Button("Refresh") then rebuildVehicles(); ui.message = "Refreshed vehicle list" end
  ImGui.SameLine()
  if ImGui.Button("Export") then exportDetected() end
end

local function selectVehicle(vehicle)
  ui.selectedId = vehicle.id
  ui.selectedPriceText = config.overrides[vehicle.id] and tostring(config.overrides[vehicle.id]) or ""
  ui.selectedFlatText = vehicle.priceFlat or ""
end

local function drawVehicleList()
  ui.search = ImGui.InputText("Search", ui.search, 128)

  if ImGui.BeginCombo("Filter", FILTERS[ui.filter] or "All") then
    for index, label in ipairs(FILTERS) do
      local selected = index == ui.filter
      if ImGui.Selectable(label, selected) then
        ui.filter = index
      end
      if selected then ImGui.SetItemDefaultFocus() end
    end
    ImGui.EndCombo()
  end

  ImGui.Separator()

  local list = filteredVehicles()
  ImGui.Text(("Vehicles: %d / %d"):format(#list, #vehicles))

  ImGui.BeginChild("vehicle_list", 0, 260)
  for _, vehicle in ipairs(list) do
    local priceText = vehicle.mapped and tostring(vehicle.currentPrice) .. " -> " .. tostring(vehicle.targetPrice) or "unmapped"
    local label = ("%s | %s | %s##%s"):format(vehicle.displayName, vehicle.type, priceText, vehicle.id)
    if ImGui.Selectable(label, ui.selectedId == vehicle.id) then
      selectVehicle(vehicle)
    end
  end
  ImGui.EndChild()
end

local function drawSelectedVehicle()
  local vehicle = vehicleById[ui.selectedId]
  if not vehicle then
    ImGui.Text("Select a vehicle.")
    return
  end

  ImGui.Separator()
  ImGui.Text(vehicle.displayName)
  ImGui.Text(vehicle.id)
  ImGui.Text("Type: " .. tostring(vehicle.type))
  ImGui.Text("Price flat: " .. tostring(vehicle.priceFlat ~= "" and vehicle.priceFlat or "unmapped"))

  if vehicle.mapped then
    ImGui.Text("Base price: " .. tostring(vehicle.basePrice))
    ImGui.Text("Current price: " .. tostring(vehicle.currentPrice))
    ImGui.Text("Target price: " .. tostring(vehicle.targetPrice))
  end

  ui.selectedPriceText = ImGui.InputText("Override price", ui.selectedPriceText, 32)
  if ImGui.Button("Save Override") then
    local value = tonumber(ui.selectedPriceText)
    if value then
      config.overrides[vehicle.id] = math.floor(value + 0.5)
      saveConfig()
      rebuildVehicles()
      ui.message = "Saved override for " .. vehicle.displayName
    else
      config.overrides[vehicle.id] = nil
      saveConfig()
      rebuildVehicles()
      ui.message = "Cleared override for " .. vehicle.displayName
    end
  end

  ImGui.SameLine()
  if ImGui.Button("Clear Override") then
    config.overrides[vehicle.id] = nil
    ui.selectedPriceText = ""
    saveConfig()
    rebuildVehicles()
    ui.message = "Cleared override for " .. vehicle.displayName
  end

  ui.selectedFlatText = ImGui.InputText("Manual price flat", ui.selectedFlatText, 160)
  if ImGui.Button("Save Manual Flat") then
    config.manualVehicles[vehicle.id] = config.manualVehicles[vehicle.id] or {}
    config.manualVehicles[vehicle.id].name = vehicle.displayName
    config.manualVehicles[vehicle.id].type = vehicle.type ~= "Unmapped" and vehicle.type or "Manual"
    config.manualVehicles[vehicle.id].priceFlat = ui.selectedFlatText
    saveConfig()
    rebuildVehicles()
    ui.message = "Saved manual flat for " .. vehicle.displayName
  end

  if vehicle.mapped then
    ImGui.SameLine()
    if ImGui.Button("Apply Selected") then
      local _, message = applyVehicle(vehicle)
      rebuildVehicles()
      ui.message = message
    end

    ImGui.SameLine()
    if ImGui.Button("Reset Selected") then
      local _, message = resetVehicle(vehicle)
      rebuildVehicles()
      ui.message = message
    end
  end
end

local function drawManualVehicleControls()
  ImGui.Separator()
  ImGui.Text("Add manual vehicle mapping")

  ui.newVehicleId = ImGui.InputText("Vehicle ID", ui.newVehicleId, 160)
  ui.newVehicleName = ImGui.InputText("Display name", ui.newVehicleName, 128)
  ui.newVehicleFlat = ImGui.InputText("Price flat", ui.newVehicleFlat, 160)

  if ImGui.Button("Add Manual Vehicle") then
    if ui.newVehicleId ~= "" and ui.newVehicleFlat ~= "" then
      config.manualVehicles[ui.newVehicleId] = {
        name = ui.newVehicleName ~= "" and ui.newVehicleName or ui.newVehicleId,
        type = "Manual",
        priceFlat = ui.newVehicleFlat
      }
      saveConfig()
      rebuildVehicles()
      ui.message = "Added manual mapping"
      ui.newVehicleId = ""
      ui.newVehicleName = ""
      ui.newVehicleFlat = ""
    else
      ui.message = "Vehicle ID and price flat are required"
    end
  end
end

local function drawWindow()
  if not overlayOpen then return end
  if not config.showWindow then return end

  local visible = ImGui.Begin("Vehicle Price Tuner")
  if not visible then
    ImGui.End()
    return
  end

  ImGui.Text(mod.name .. " " .. mod.version)
  if ImGui.Button("Hide Window") then
    config.showWindow = false
    saveConfig()
    ImGui.End()
    return
  end

  if ui.message ~= "" then
    ImGui.Text(ui.message)
  end

  drawGlobalControls()
  drawVehicleList()
  drawSelectedVehicle()
  drawManualVehicleControls()

  ImGui.End()
end

local function autoApply(reason)
  ensureFilesLoaded()
  rebuildVehicles()

  if not autoApplied and config.applyOnInit and config.enabled then
    applyAll()
    autoApplied = true
    log(("Auto-applied prices during %s"):format(reason))
  end
end

local function runtimeRetry(delta)
  updateTimer = updateTimer + (tonumber(delta) or 0)
  if updateTimer < 1.0 then
    return
  end
  updateTimer = 0

  if retryCount >= 120 then
    return
  end
  retryCount = retryCount + 1

  local ok, err = pcall(function()
    ensureFilesLoaded()
    if #vehicles == 0 then
      rebuildVehicles()
    end

    if config.enabled then
      if not autoApplied and config.applyOnInit then
        applyAll()
        autoApplied = true
        log("Auto-applied prices during onUpdate retry")
      else
        syncVcdCache()
      end
    end
  end)

  if not ok then
    log("Runtime retry failed: " .. tostring(err))
  end
end

registerForEvent("onTweak", function()
  autoApply("onTweak")
end)

registerForEvent("onInit", function()
  ensureFilesLoaded()
  rebuildVehicles()
  log(("Loaded %d vehicles"):format(#vehicles))

  if not autoApplied and config.applyOnInit and config.enabled then
    applyAll()
    autoApplied = true
  end
end)

registerForEvent("onDraw", function()
  drawWindow()
end)

registerForEvent("onUpdate", function(delta)
  runtimeRetry(delta)
end)

registerForEvent("onOverlayOpen", function()
  overlayOpen = true
  config.showWindow = true
end)

registerForEvent("onOverlayClose", function()
  overlayOpen = false
end)

log("Script registered")
