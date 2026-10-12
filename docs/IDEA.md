NotchClaw is an app that is designed to orchestrate, monitor and manage openclaw from the notch of macbook air.

> Benchmarking boringnotch (https://github.com/TheBoredTeam/boring.notch) for technicalities and notch implementation, the NotchClaw is an MacOS-only app designed for apple silicon.

# Functionalities

- Lives in the notch, and when the mouse is hovered nearby, the notch expands (just like boringnotch)
- Can connect to openclaw gateways via url and token
- Smooth animations, you can choose an emoji (UTF-8) to represent the openclaw agent. 
- Can set shortcuts for press-and-talk to comminucate with the agent without using the keyboard
- when Not hovering the mouse at the notch, the notch goes back to minimal state, but when the agent has replied, answered or need the user's input or advice, the notch glows around the edges with a beautiful siri-like color combination (like a neon light), making the user notice.
- For users that use codex login models for openclaw, the notch offers a current codex subscription usage view on the right end, with a bar indicating (5hr/daily/weekly) usage. the user can choose which usage to show. 
- If openclaw replied in a long text, the bar can expand way bigger, taking up half the vertical height of the screen and 1/3 horizontal width of the screen (expand limit can be manually set in the settings)
- when hovering, the bar has smooth animations, and when the agent is thinking, an indicator (you think of a good way) shows that the agent is thinking.
- The outputs of the agent is prettified as much as possible. when the agent is asked via NotchClaw, an instruction injection happens that makes the agent reply in a markdown format, so the agent always answers in a markdown format for this app. So the output will be shown prettified in a markdown viewer way. 
- There are basic settings to set the model, effort and compaction (or some more basic settings) in the main screen when hovered (find a good place to put these buttons). Or the user's press-and-talk can also change those settings. 
- If disconnected from the gateway or network, the notch shows a minimal but stylish way or telling the user that the network is disconnected. and when the network is back on, the app auto reconnects fast.

# Styling

Use the following design skills, and find new design skills that you think will be the best for this app, using find-skills skill.

- macos-app-design

# Developing

## Git

Utilize git to the fullest. The project is currently empty with only `git init` done.

## Language

Use the best fit language from your opinion for this project, try not to use too much bloat.

## Permissions

If you need any `sudo` command ask me for permission, but all the other things are at your fingertips.

## Testing & Release

When you finish building, save a *.dmg file of that release to the desktop (~/Desktop). I will download and test it, and give you feedback. 
If I downloaded, tested and gave you feedback or something to fix, firstly delete the *.dmg from the desktop and delete the currently installed NotchClaw application, then fix according to feedback and save the new version of the *.dmg to the desktop again.

