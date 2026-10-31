# 10. Key Commands

This chapter lists every keyboard shortcut in Ongaku Studio, plus the mouse gestures that change when you hold a modifier key. Many shortcuts are the same as Logic Pro's, so if you know Logic they'll feel familiar. If you don't, start with the handful in "The keys you'll use most" and pick up the rest as you go.

## How focus affects which keys work

Ongaku Studio has two kinds of shortcut, and they behave a little differently.

**Single keys** (Space, Return, R, C, K, E and so on) are the Logic-style shortcuts. They work anywhere in the project window, wherever you last clicked, with two exceptions:

- **While you're typing in a text field** (a track name, the tempo, the Library's search field, a chord name), keys type text instead. Press **Return** to finish typing or **Escape** to cancel. Clicking in the tracks area or an editor also ends typing, so the shortcuts work again straight away.
- **They only work in the project window.** If a plug-in window or the Settings window is in front, click the project window first. Space won't start playback from a plug-in window.

They're shown next to their commands in the menus, the same as ⌘ shortcuts: for example **Transport › Play** shows Space, and **View › Show Editor** shows E. Choosing the menu item does the same as pressing the key.

**Shortcuts with ⌘** (⌘B, ⌘T, ⌘R…) are ordinary menu shortcuts. They're shown next to their menu items and work whenever a project window is in front.

**Where you clicked last matters.** The project window remembers whether you last clicked in the **tracks area** (the regions at the top) or the **editor pane** (the Piano Roll and the other editors at the bottom). While the editor pane is open, the area your keys act on has a **thin blue outline**; click in the other area to move it. That decides what some keys act on:

- **Delete** removes the selected *notes* (or selected MIDI Draw points) if you last clicked in the Piano Roll. If you last clicked in another editor (the Step Editor, Step Sequencer, Drummer and so on), it does nothing. If you last clicked a chord on the Chord track, it removes that chord. Otherwise it removes the selected *regions*. With nothing selected, it does nothing. Delete never deletes tracks; use ⌘⌫ for that.
- **⌘X**, **⌘C**, **⌘V**, **⌘A** and **⌘R** act on *notes* if you last clicked in the Piano Roll (with a MIDI region open in it). Otherwise they act on *regions*. The Edit menu even renames **Repeat Regions** to **Repeat Notes** to show which one you'll get.
- **⌥←** and **⌥→** nudge the selected *notes* if you last clicked in the Piano Roll, and the selected *regions* if you last clicked in the tracks area.
- **Q**, **⌥↑** and **⌥↓** only work in the Piano Roll, and only after you've clicked in it.
- **T** opens the Tool menu for the area the pointer is over. If the pointer is over neither area, you get the menu for the one you clicked last.

## The keys you'll use most

| Shortcut | Command | Notes |
| --- | --- | --- |
| Space | Play or stop | |
| Return | Go to the beginning | |
| R | Record | Press again (or Space) to stop. |
| C | Cycle on or off | |
| ⌘Z | Undo | |
| ⇧⌘Z | Redo | |
| E | Show or hide the editor | Opens whichever editor suits the region. |
| X | Show or hide the mixer | |

## File and project

| Shortcut | Command | Notes |
| --- | --- | --- |
| ⌘N | **File › New** | What a new project contains is set in **Settings › General**. |
| ⌘O | **File › Open…** | |
| ⌘S | **File › Save** | |
| ⇧⌘S | **File › Duplicate** | Standard macOS. Hold ⌥ in the File menu for **Save As…**. |
| ⌘W | **File › Close** | |
| ⇧⌘I | **File › Import Audio Files…** | Also the **Import Audio** button in the control bar. |
| (none) | **File › Import MIDI File…** | No shortcut. You can also drag MIDI files onto the tracks area. |
| ⌘B | **File › Bounce…** | See [Chapter 9](09-library-bounce-files-settings.md). |
| (none) | **File › Export Project as MIDI File…** | No shortcut. |
| (none) | **File › Mastering…** | Opens Mastering on Stereo Out, adding it first if it isn't there. See [Chapter 8](08-instruments-effects-midi-fx.md#mastering). |
| (none) | **File › Analyze Whole Song for Mastering** | Mastering listens to the whole song offline. See [Chapter 8](08-instruments-effects-midi-fx.md#analyze-whole-song). |
| ⌘, | **Ongaku Studio › Settings…** | |
| ⌘Q | **Ongaku Studio › Quit Ongaku Studio** | |

## Transport

| Shortcut | Command | Notes |
| --- | --- | --- |
| Space | Play / Stop | **Transport › Play** or **Stop**. |
| Return or Enter | Go to Beginning | Moves the playhead to the start of the project. |
| , (comma) | Back One Bar | From inside a bar, the first press goes to the start of that bar. |
| . (period) | Forward One Bar | |
| R | Record / Stop Recording | |
| C | Turn Cycle On / Off | |
| K | Turn Metronome On / Off | The sound is set in **Settings › Metronome**. Saved with the project, and undoable. |
| (none) | Count-in on / off | The **Count-in** button in the control bar. No key. |
| ⌥' | Create Marker | Adds a marker at the playhead (snapped to the grid) and shows the global tracks. |
| ⌥, | Go to Previous Marker | |
| ⌥. | Go to Next Marker | |

## Editing

These work on regions in the tracks area, or on notes in the Piano Roll if you clicked there last (see "How focus affects which keys work"). While you're typing in a text field, ⌘X, ⌘C, ⌘V and ⌘A cut, copy, paste and select text as usual.

| Shortcut | Command | Notes |
| --- | --- | --- |
| ⌘Z | Undo | Every edit can be undone. |
| ⇧⌘Z | Redo | |
| ⌘X | Cut | Regions or notes. |
| ⌘C | Copy | Regions or notes. |
| ⌘V | Paste | Regions or notes. |
| ⌘A | Select All | All regions, or all notes in the open region. |
| Delete or Forward Delete | **Edit › Delete Selection** | Deletes the selected regions, or the selected notes if you clicked in the Piano Roll last. With nothing selected, it does nothing. It never deletes tracks. |
| ⌘R | Repeat Regions / Repeat Notes | Places a copy straight after the selection. |
| ⌘T | Split Regions at Playhead | Splits the selected regions, or, with none selected, every region under the playhead on the selected track. |
| ⌘J | Join Regions | Needs at least two selected regions. |
| ⌥← / ⌥→ | Nudge regions | Moves the selected regions one snap-grid step earlier or later, in the tracks area. One undo step per press. (In the Piano Roll, these nudge notes.) |
| ⌥⌘F | Pack Take Folder | Turns the selected regions into one take folder. It's in the **Edit** menu, not the Track menu. Needs at least two selected regions. |

### Section Between Locators

These edit the whole song between the cycle locators, across every track. They're under **Edit › Section Between Locators**, and need a cycle range to be set.

| Shortcut | Command | Notes |
| --- | --- | --- |
| ⌃⌘X | Cut Section | Removes the section and closes the gap. |
| ⌃⌘Z | Insert Silence | Opens up an empty gap the length of the cycle range. |
| ⌃⌘R | Repeat Section | Repeats the section straight after itself. |

## Tools

Press **T** to open the Tool menu, then press the tool's key. Each tool's key is shown in the menu. **Escape** closes the menu without changing tools. Any other key also closes it. You can also click a tool in the menu, or use the tool button at the top of the track headers (or of the Piano Roll).

The keys pressed after T mean something different from the same keys on their own. **T** then **E** picks the Eraser and doesn't open the editor, and **T** then **I** picks the Scissors and doesn't open the Inspector.

### Tracks area tools

| Shortcut | Command | Notes |
| --- | --- | --- |
| T, then T | Pointer Tool | Select, move and resize regions. |
| T, then P | Pencil Tool | Click an empty instrument lane to add a region. |
| T, then E | Eraser Tool | Click a region to delete it. |
| T, then I | Scissors Tool | Click a region to split it there. |
| T, then G | Glue Tool | Click a selected region to join the selected regions. |
| T, then M | Mute Tool | Click a region to mute or unmute it. |
| T, then A | Fade Tool | Drag over an audio region's start or end to fade it, or where two regions meet or overlap to crossfade. |

### Piano Roll tools

Click in the Piano Roll (or point at it) before pressing T.

| Shortcut | Command | Notes |
| --- | --- | --- |
| T, then T | Pointer Tool | Select, move and resize notes. Drag in empty space to select several. |
| T, then P | Pencil Tool | Click to add a note, dragging to set its length. |
| T, then B | Brush Tool | Drag to paint notes along the grid. |
| T, then E | Eraser Tool | Click a note to delete it (or the selection, if it's selected). |
| T, then I | Scissors Tool | Click a note to split it there. |
| T, then G | Glue Tool | Click a selected note to join the selected notes of each pitch. |
| T, then M | Mute Tool | Click a note to mute or unmute it. |
| T, then V | Velocity Tool | Drag a note up or down to change its velocity (and the selection's). |
| T, then Q | Quantize Tool | Click a note to quantize it (or the selection) to the grid. |
| Hold ⌘ | Pencil, temporarily | While the Pointer is chosen, holding ⌘ gives you the Pencil. |

## Tracks

| Shortcut | Command | Notes |
| --- | --- | --- |
| ⌥⌘A | **Track › New Audio Track** | |
| ⌥⌘S | **Track › New Software Instrument Track** | |
| ⌥⌘U | **Track › New Drummer Track** | |
| (none) | **Track › New Drummer Track (Drum Machine)** | No shortcut. A drummer on the Ongaku Drum Machine. |
| (none) | **Track › New Aux Track** | No shortcut. |
| (none) | **Track › New Bass Player Track**, **New Keyboard Player Track** | No shortcut. See [Chapter 5](05-session-players.md). |
| (none) | **Track › New Pattern Region** | No shortcut. On the selected instrument track, at the playhead's bar. |
| ⌘D | **Track › Duplicate Track** | |
| ⌘⌫ (⌘-Delete) | **Track › Delete Track** | Deletes every selected track (the menu says **Delete Tracks** when several are selected). A summing stack takes its subtracks with it. One ⌘Z brings them all back. |
| ⇧⌘D | **Track › Create Summing Stack** | Groups the selected tracks into a stack. |
| (none) | **Track › Flatten Stack** | No shortcut. |
| (none) | **Track › Freeze Tracks** / **Unfreeze Tracks** | No shortcut. |
| (none) | **Track › Add Arrangement Marker** | No shortcut. |
| (none) | **Track › Detect Chords** | No shortcut. Fills the Chord track from the selected MIDI regions. |
| G | **Track › Show Global Tracks** / **Hide Global Tracks** | |

## Views, panes and windows

| Shortcut | Command | Notes |
| --- | --- | --- |
| Y | Show / Hide Library | Also the **Library** button and **View › Show Library**. |
| I | Show / Hide Inspector | Also the **Inspector** button and **View › Show Inspector**. |
| E | Show / Hide Editor | Also the **Editor** button and **View › Show Editor**. Opens the selected region in whichever editor suits it: Piano Roll, Step Editor, Step Sequencer, Drummer, Player, Takes or Flex Pitch. |
| X | Show / Hide Mixer | Also the **Mixer** button and **View › Show Mixer**. The mixer and the editor share the bottom of the window, so showing one hides the other. |
| A | Show / Hide Automation | Also the **Automation** button and **View › Show Automation**. |
| G | Show / Hide Global Tracks | It's in the **Track** menu (**Track › Show Global Tracks**), not the View menu. There's no control bar button. |
| ⌘= | Zoom In | Zooms the tracks area. Also the zoom buttons in the control bar. |
| ⌘- | Zoom Out | |
| ⌘M | Minimize window | Standard macOS. |

## Piano Roll

These work when the Piano Roll is showing a MIDI region and you last clicked in it. The general editing keys (⌘X, ⌘C, ⌘V, ⌘A, ⌘R, Delete) act on notes here too.

| Shortcut | Command | Notes |
| --- | --- | --- |
| Q | Quantize | Quantizes the selected notes to the grid, using the strength and swing set in the Piano Roll's Quantize controls. **With nothing selected, it quantizes every note in the region.** |
| ⌥↑ | Transpose up a semitone | Selected notes only. |
| ⌥↓ | Transpose down a semitone | |
| ⌥⇧↑ | Transpose up an octave | |
| ⌥⇧↓ | Transpose down an octave | |
| ⌥← | Nudge left one grid step | Selected notes only. The step is the Piano Roll's grid setting. |
| ⌥→ | Nudge right one grid step | |
| Delete | Delete selected notes | If points are selected in the MIDI Draw lane, Delete removes those instead. With nothing selected, it does nothing. |

## Step Editor and Step Sequencer

The Step Editor and Step Sequencer have no keys of their own. They're mouse-driven (see the gestures table below). The transport and view keys still work while they're showing. **Delete** does nothing while you're working in them (or in the Drummer, Player, Takes and Flex Pitch editors), so it can't remove Piano Roll notes you can't see. See [Chapter 4](04-midi-editing.md).

## Mixer

The mixer has no keys of its own apart from **X** to show and hide it. Its reset gestures are in the table below. See [Chapter 7](07-mixing-and-automation.md).

## Dialogs, text fields and plug-in windows

| Shortcut | Command | Notes |
| --- | --- | --- |
| Return | Confirm | In the Bounce dialog this is **Bounce** and then **Save…**. It also confirms a new track name, tempo, chord, fade length or preset name. |
| Escape | Cancel | In the Bounce dialog this is **Cancel** or **Discard**. It also cancels typing a track name, tempo, fade length or plug-in value, and closes the Tool menu. |
| ⌘Z | Undo (in a plug-in window) | In the window of an Ongaku plug-in, ⌘Z undoes your last change to that plug-in's settings, the same as its header's undo button. |
| ⇧⌘Z | Redo (in a plug-in window) | |

## Mouse and modifier gestures

### Tracks area

| Shortcut | Command | Notes |
| --- | --- | --- |
| Click | Select a region | With the Pointer or Pencil. Other tools act on the region instead. |
| ⇧-click | Add a region to the selection, or take it away | |
| Drag a region | Move it (also to another track) | Snaps as set with the **Snap** button above the track headers (or **Settings › General › Snap regions to**). |
| ⌃ while dragging | Move freely, off the grid | Press Control after the drag starts (a Control-click is a right-click). Works for regions, their edges, notes and automation points. |
| ⌥-drag a region | Copy it | The pointer shows a +, and the original stays where it was. What counts is whether ⌥ is held when you let go. |
| Drag a region's left or right edge | Resize it | |
| Drag the upper half of a region's right edge | Loop it | The pointer changes to show the loop handle. |
| Drag across empty space | Select regions with a rubber band | Pointer only. Hold ⇧ to add to the selection. |
| Double-click a region | Open it in the editor | |
| Double-click an empty instrument lane | Create a MIDI region | The Pencil does this with a single click. |
| Drag in the lower half of an audio region | Flex Time | When Flex is on. See [Chapter 6](06-flex-and-smart-tempo.md). |
| Double-click a flex marker | Delete the flex marker | Only while the track's Flex mode is on. |
| Fade Tool: drag where two audio regions meet or overlap | Crossfade them | See [Chapter 2](02-arranging-and-editing.md#making-a-crossfade). |
| Right-click a region or lane | Region menu | Cut, Copy, Paste, Repeat, Split, Loop, New MIDI/Pattern/Drummer/Player Region, Take Folder and more. |
| Drag in the ruler's upper strip | Set the cycle range | Click the strip to turn cycle on or off. |
| Click the ruler's lower part | Move the playhead | |

### Track headers

| Shortcut | Command | Notes |
| --- | --- | --- |
| Click | Select a track | |
| ⇧-click | Select every track between this one and the last one clicked | |
| ⌘-click | Add or remove one track from the selection | |
| Double-click the track name | Rename | Return to confirm, Escape to cancel. |
| Right-click | Track menu | Rename, stack, freeze, instrument, **Color** and **Delete Track**. On one of several selected tracks, it's **Delete Tracks** and deletes them all. |
| Right-click the snowflake | **Freeze Mode** | Choose **Pre Fader** or **Source Only** (not while the track is frozen). |
| Double-click the divider between headers and lanes | Reset the header width | |

### Global tracks

| Shortcut | Command | Notes |
| --- | --- | --- |
| Double-click an empty spot on the Marker track | Add a marker | |
| Click a marker | Move the playhead there | Drag to move it, double-click to rename it. |
| Drag an arrangement section | Move it, with everything in it | Drag its right edge to resize it. Click to select it with its regions. Double-click to rename it. |
| Double-click an empty spot on the Chord track | Add a chord | Double-click a chord to change it, drag it along the grid, right-click for more. |
| Click a chord | Select it and move the playhead there | Then Delete (or **Edit › Delete Selection**) removes it. |
| Drag a tempo handle up or down | Change the tempo | Drag sideways to move the change. |
| Double-click an empty spot on the Tempo track | Add a tempo change | |
| Click a time signature | Open its box | Set the beats, the beat unit or a common meter, or **Delete** it. |
| Click **+** beside **Signature** | Add a time signature change at the next bar | Opens its box. |
| Drag a time signature change | Move it to another bar | Right-click to change or delete it. |

### Control bar and window

| Shortcut | Command | Notes |
| --- | --- | --- |
| Double-click the tempo | Type a new tempo | Return to confirm, Escape to cancel. |
| Click the time signature or key | Choose a new one | |
| Click **Count-in** | Count-in on or off | Uses the length set in **Settings › Recording**. |
| Click the **Fade In** or **Fade Out** number in the Region Inspector | Type a fade length | "250", "250 ms" or "1.5 s". Return to confirm, Escape to cancel. |
| Drag the divider above the editor or mixer | Resize the pane | Double-click it to go back to the default height. |

### Automation lanes

| Shortcut | Command | Notes |
| --- | --- | --- |
| Click the automation strip | Add a point | The strip is under the track's lane while automation is shown (A). Points snap to the grid. |
| Drag a point | Move it | Hold ⌃ after you start dragging to move it off the grid. |
| Double-click a point | Delete it | |

### Piano Roll

| Shortcut | Command | Notes |
| --- | --- | --- |
| Click a note | Select it (and hear it) | |
| ⇧-click a note | Add it to the selection | |
| Drag a note | Move the selection (time and pitch) | Snaps to the grid unless the **Snap** button is off. Hold ⌃ after you start dragging to move freely. |
| ⌥-drag a note | Copy the selection | The originals stay where they are. |
| Drag a note's start or end | Resize it (and the rest of the selection) | |
| Double-click empty space | Add a note | Pointer tool. |
| Drag across empty space | Select notes with a rubber band | Hold ⇧ to add to the selection. |
| Hold ⌘ and click or drag | Pencil tool | While the Pointer is chosen. |
| Click a key on the keyboard | Select every note of that pitch | ⇧-click adds them to the selection. |
| Right-click | Note menu | Cut, Copy, Paste, Repeat, Delete, selection commands and note functions (Quantize, Transpose, Velocity, Humanize…). |

### MIDI Draw lane

| Shortcut | Command | Notes |
| --- | --- | --- |
| Drag a velocity stalk | Change a note's velocity | All selected notes move together. |
| Drag across empty space (velocity) | Sweep velocities to the pointer's height | |
| Click empty space (controllers) | Add a point | |
| Drag across empty space (controllers) | Draw freehand | |
| ⇧-click | Add to the selection | |
| Drag the lane's top edge | Change the lane's height | |

### Step Editor, Step Sequencer and other editors

| Shortcut | Command | Notes |
| --- | --- | --- |
| Click a step (Step Editor) | Set an event to the height clicked | |
| Drag across steps (Step Editor) | Paint events | |
| Double-click a bar (Step Editor) | Remove it | |
| Click a step (Step Sequencer) | Turn it on or off | |
| Drag across steps (Step Sequencer) | Paint steps | The edit mode chooses what painting changes. |
| Drag across a take (Takes editor) | Make that take play there | Quick-swipe comping. Click a take's name to play it throughout. |
| Right-click a take (Takes editor) | Take menu | **Rename…** or **Delete Take**. |
| Drag a note (Flex Pitch) | Retune it | Double-click to put it back. |

### Mixer and plug-ins

| Shortcut | Command | Notes |
| --- | --- | --- |
| Click a channel strip | Select its track | ⇧-click and ⌘-click select more tracks, as on the track headers. |
| ⌥-click a fader | Reset to 0 dB | |
| Double-click or ⌥-click a knob | Reset to its default | Pan knobs go to the centre, send knobs to −6 dB. |
| Click an insert slot | Open the plug-in's window | Also on Stereo Out. |
| Hold or ⌃-click an insert or MIDI FX slot | Slot menu | **Bypass**, **Move Up**, **Move Down**, **Remove** and more. |
| ⌥-click a plug-in knob or value | Reset it to its default | In every Ongaku plug-in, effects and instruments. One step in the window's undo. |
| Double-click a plug-in value | Type a value | In Ongaku effects. Escape cancels. |
| Double-click a plug-in knob | Reset it | In Ongaku instruments (Retro Synth, Drum Machine, Sampler), and the Session Drummer's **Fills** and **Swing** knobs. |
