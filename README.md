# Vehicle Price Tuner

Cyberpunk 2077 CET mod for changing vehicle purchase prices.

## Status

Initial implementation. The mod provides:

- CET ImGui window
- global VCD/modded vehicle multiplier
- global vanilla AutoFixer/manual vehicle multiplier
- minimum price and rounding
- individual per-vehicle overrides
- reset selected / reset all
- detected vehicle export
- safe state tracking to avoid repeated multiplier stacking
- data-driven vanilla AutoFixer purchase offer mapping
- generated TweakXL override file for vanilla AutoFixer prices

## Install

Copy this repository folder to:

```text
Cyberpunk 2077/bin/x64/plugins/cyber_engine_tweaks/mods/vehicle_price_tuner
```

The folder must contain `init.lua`.

## Usage

Open the CET overlay. The **Vehicle Price Tuner** window is enabled by default.

The window is only drawn while the CET overlay is open.

VCD and AutoFixer Customs vehicles are detected through:

```text
Vehicle.some_vehicle.dealerPrice
```

Use **Apply All** to write the current global rules and per-vehicle overrides. Use **Reset All** to restore tracked base prices.

VCD and AutoFixer Customs prices update at runtime through the VCD cache. Reopen the store page if it was already open.

Vanilla AutoFixer purchase vehicles are mapped through:

```text
EconomicAssignment.some_vehicle.overrideValue
```

CET cannot reliably write those integer flats at runtime, so the mod generates:

```text
Cyberpunk 2077/r6/tweaks/VehiclePriceTuner/vehicle_price_tuner.yaml
```

Use **Apply All** or **Write Vanilla File** after changing vanilla multipliers or per-vehicle overrides, then restart the game. TweakXL loads the generated file during startup, so vanilla prices will not change in an already-running game.

The default manifest is generated from the game's REDmod vehicle offer data:

```text
data/vanilla_vehicles.json
```

Use the manual mapping controls in the CET window for other compatibility targets.

## First Test

1. Install the mod into the CET `mods` folder.
2. Start the game and open the CET overlay.
3. Click **Export** and inspect `detected_vehicles.json`.
4. Set a VCD/modded multiplier, or enter an individual override.
5. Click **Apply All** or **Apply Selected**.
6. Reopen the vehicle store page if it was already open, then check the price in-game.
7. For vanilla AutoFixer prices, restart the game after **Apply All** or **Write Vanilla File**.

## Notes

The mod does not edit other mods' files. It writes runtime VCD cache overrides, generates one owned TweakXL file for vanilla prices, and stores its own state in `state.json`.
