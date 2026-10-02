# Smarter Recruits

**Author**: Monsterfish
**Version**: 1.0.10

Small fixes and buttons for the troops you recruit. Every part can be switched off in the
settings.

## Horse archers fight on the way to the rally point

Fresh horse archers used to ride to their rally point without shooting, and once there they
stood still and ignored the enemy, unlike every other ranged unit. Now they shoot while they
ride and react normally once they arrive.

Your horse archers also never stop or turn aside for enemies on the way: they shoot from the
saddle and keep riding, and while waiting at the rally point they keep shooting and still ride
to it again when you move it, whatever their stance.

## Recruits keep your new orders

If you sent a freshly recruited unit somewhere else before it reached its rally point, it
went to the new spot and then walked off to the rally point anyway. Now it stays where you
sent it.

## Recruits fight their way to the rally point

Recruits in the defensive or aggressive stance (see the stance button below) handle enemies
on the way to their rally point like patrolling troops: ranged units stop and shoot, melee
units go for the enemy, and when the way is clear they walk on to the rally point. Recruits
in the normal stance walk there as before.

Recruits in the aggressive stance run to the rally point instead of walking, if their kind of
soldier can run (archers, spearmen, macemen, knights, Arab archers, slaves, slingers, monks).

Recruits without a rally point gather at the building that made them and react to enemies
there the same way.

Like every recruit in the game, they then wait at the rally point and walk to it again when
you move it, fighting their way there each time, until you select them. While they wait
there they react to enemies the way idle troops in their stance do.

## Terrain and monks

Fresh recruits now walk to their rally point at the speed the ground allows (slower uphill,
through marsh and so on) instead of at full speed everywhere. Monks now really go to their
rally point: the game used to check only one spot there and sent them to the cathedral's
door whenever it was taken.

## Rally point buttons

Every unit picture in the barracks, mercenary post, engineer's guild, tunneler's guild and
cathedral gets a small button in its top right corner. Click it and then click on the map to
set the rally point for that unit - the same as the number keys, but you can see which
button belongs to which unit. Clicking anywhere else on the picture still recruits. Hovering over a button shows what
it does at the top left of the panel.

## Stance button

The barracks and the mercenary post get a stance button on their last unit picture (bottom
right corner), the guilds and the cathedral on their unit picture. Each click switches
between normal, defensive and aggressive. Every unit you recruit from then on starts in that
stance. It works in single player games (scenarios and skirmishes).

## Changing the button pictures

The buttons are PNG files in the module's `images` folder:

- `rally.png` - the rally point button
- `stance_normal.png`, `stance_defensive.png`, `stance_aggressive.png` - the stance button

Replace them with your own pictures (any size up to 256x256). Their transparency is used,
soft edges included. Or give a picture an alpha mask: a grey picture of the same size named
like the button with `_alpha` at the end, for example `rally_alpha.png` - white is solid,
black is see-through, grey is in between. For a different picture while the mouse is over a button, add a file of the same size
named like the button with `_hover` at the end, for example `rally_hover.png`. Without one
the button is drawn a little brighter. Restart the game after changing a picture.
