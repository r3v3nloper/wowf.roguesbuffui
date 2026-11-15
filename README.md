# Rogue's Buffs UI (WoW Forever)

Shows the rogue buffs you apply **yourself** as icons you can move anywhere on screen, and warns you when they run out.

## What gets shown

| Icon | Shows | Alert |
|---|---|---|
| **Slice and Dice** | Running time as a countdown and a swipe | Out of combat a missing Slice and Dice is only shown faded. **In combat** it turns red and blinks, and you get a sound plus text when it runs out. In the last 3 seconds the border turns yellow. |
| **Poison main hand (MH)** | Whether poison is on the weapon, time left, charges | When the poison is gone, when it is almost used up (default: under 5 min or under 10 charges), and as a reminder when combat starts while a weapon has no poison |
| **Poison off hand (OH)** | Same as main hand. Only appears if you carry an off-hand weapon | Same as main hand |
| **Your own buffs** | Any buff you add with `/rbu add` | When it runs out |

In WoW Forever, poisons sit on the weapon (like a sharpening stone), not on your character. That's why the addon reads the weapon enhancement.

## Installation

1. Copy the `RoguesBuffsUI` folder to `...\World of Warcraft\<Forever folder>\Interface\AddOns\`.
2. Start the game or type `/reload`.
3. Type `/rbu unlock`, drag the icons (e.g. below your character) and the alert text (e.g. center of the screen) to where you want them, then type `/rbu lock`.

## Commands

| Command | Does |
|---|---|
| `/rbu` | Opens the settings (Esc > Options > AddOns > Rogue's Buffs UI) |
| `/rbu unlock` / `/rbu lock` | Move the frames / lock them again |
| `/rbu reset` | Puts the frames back where they started |
| `/rbu test` | Shows a test alert |
| `/rbu scan` | Lists your current buffs with their ID |
| `/rbu add <ID or name>` | Tracks another buff. Add `kampf` at the end to get alerts only in combat |
| `/rbu list` / `/rbu remove <number>` | Shows your own buffs / removes one |
| `/rbu debug` | Technical status, in case something doesn't work |

Settings: lock frames, which icons to show, "only show missing buffs", sound, alert text, icon size, scale, and when the poison warning fires.

## Known limits (please read)

- **Tested only for syntax, not yet in the game.** The addon was written against the Blizzard API, but it hasn't run in WoW Forever yet.
- **Combat:** WoW Forever uses Midnight's addon restrictions. The game may hide buff details from addons in combat ("secret values"). The addon handles this as follows:
  1. Out of combat it reads the real running time and keeps counting it down in combat.
  2. When you cast Slice and Dice in combat, it estimates the duration from your combo points (shown with `~` in front of the time). After the first time it could read the real duration, it uses that instead.
  3. A `?` means: the buff is there, but the game won't reveal how long it lasts.
- **Sharpening stones / weightstones** probably also count as a weapon enhancement. If you have a stone on the weapon and no poison, the addon may think poison is on it. Check this with `/rbu debug`.
- Slice and Dice is recognized by its name or by the spell IDs 5171, 6774 and 315496. If Forever uses a different ID, the addon learns it automatically once it has seen the buff out of combat.

## If something doesn't work

Type `/rbu debug` (once out of combat, once in combat with Slice and Dice up) and send a screenshot. Important lines:
- `snd: active src=aura` = everything is fine, the game lets the addon read the buff.
- `src=cache` or `src=estimate` = the game hides the buff in combat, and the addon is working from cached or estimated times.
- `weaponEnchant: true, 1234567, 0, ...` = poison on the main hand (true), time left in milliseconds, charges.
