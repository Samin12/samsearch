import { Action, ActionPanel, Icon, List, Toast, closeMainWindow, popToRoot, showHUD, showToast } from "@raycast/api";
import { basename } from "node:path";
import { useEffect, useState } from "react";
import { Screen, captureScreen, prefs, startT3Thread, taskForT3 } from "./lib";

export default function Command() {
  const { projects, useScreen } = prefs();
  const [text, setText] = useState("");
  const [project, setProject] = useState(projects[0]);
  const [screen, setScreen] = useState<Screen | null>(null);

  // Ready in case you want to send what you were looking at (⌘S).
  useEffect(() => {
    if (useScreen) captureScreen().then(setScreen);
  }, []);

  async function start(withScreen: boolean) {
    const message = text.trim();
    if (!message) return;
    const toast = await showToast({ style: Toast.Style.Animated, title: "Starting T3 thread…" });
    try {
      await startT3Thread(taskForT3(message, [], withScreen ? screen : null), { project });
      await closeMainWindow();
      await popToRoot();
      await showHUD(`Started in T3 Code · ${basename(project)}`);
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "Couldn't start a T3 thread";
      toast.message = e instanceof Error ? e.message : String(e);
    }
  }

  return (
    <List
      searchText={text}
      onSearchTextChange={setText}
      filtering={false}
      searchBarPlaceholder="What should the agent do?"
      searchBarAccessory={
        <List.Dropdown tooltip="Project" value={project} onChange={setProject}>
          {projects.map((p) => (
            <List.Dropdown.Item key={p} title={basename(p)} value={p} icon={Icon.Folder} />
          ))}
        </List.Dropdown>
      }
    >
      <List.Item
        title={text.trim() || "Type the task for a new T3 thread"}
        subtitle={`${basename(project)} · default model and settings · ⌘S adds your screen`}
        icon={Icon.Terminal}
        actions={
          <ActionPanel>
            <Action title="Start Thread" icon={Icon.Terminal} onAction={() => start(false)} />
            {screen && (
              <Action
                title={`Start with Screenshot of ${screen.app}`}
                icon={Icon.Eye}
                shortcut={{ modifiers: ["cmd"], key: "s" }}
                onAction={() => start(true)}
              />
            )}
          </ActionPanel>
        }
      />
    </List>
  );
}
