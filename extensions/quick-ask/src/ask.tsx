import {
  Action,
  ActionPanel,
  Detail,
  Icon,
  List,
  Toast,
  closeMainWindow,
  popToRoot,
  showHUD,
  showToast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { HANDOFF, Screen, Turn, ask, captureScreen, prefs, startT3Thread, taskForT3 } from "./lib";

type Mode = "auto" | "answer";

export default function Command() {
  const { useScreen } = prefs();
  const [text, setText] = useState("");
  const [history, setHistory] = useState<Turn[]>([]);
  const [screen, setScreen] = useState<Screen | null>(null);
  const [screenOn, setScreenOn] = useState(useScreen);
  const [capturing, setCapturing] = useState(useScreen);
  const { push } = useNavigation();

  // Grab the window behind the launcher right away, so it's ready by the time you hit Enter.
  useEffect(() => {
    if (!useScreen) return;
    captureScreen()
      .then(setScreen)
      .finally(() => setCapturing(false));
  }, []);

  const seen = screenOn ? screen : null;

  function submit(mode: Mode) {
    const question = text.trim();
    if (!question) return;
    setText("");
    push(<Answer question={question} history={history} screen={seen} mode={mode} onDone={(t) => setHistory((h) => [...h, t])} />);
  }

  async function toT3() {
    const question = text.trim();
    if (!question) return;
    await handOff(taskForT3(question, history, seen), question);
  }

  const screenLabel = capturing ? "Looking at your screen…" : screen ? `Sees ${screen.app}` : "Couldn't see the screen";

  const actions = (
    <ActionPanel>
      <Action title="Ask" icon={Icon.Stars} onAction={() => submit("auto")} />
      <Action title="Answer Here" icon={Icon.Bubble} shortcut={{ modifiers: ["cmd"], key: "return" }} onAction={() => submit("answer")} />
      <Action title="Start T3 Thread" icon={Icon.Terminal} shortcut={{ modifiers: ["cmd", "shift"], key: "return" }} onAction={toT3} />
      <Action
        title={screenOn ? "Don't Use Screen" : "Use Screen"}
        icon={Icon.Eye}
        shortcut={{ modifiers: ["cmd"], key: "s" }}
        onAction={() => setScreenOn((v) => !v)}
      />
      {history.length > 0 && (
        <Action title="New Conversation" icon={Icon.Plus} shortcut={{ modifiers: ["cmd"], key: "n" }} onAction={() => setHistory([])} />
      )}
    </ActionPanel>
  );

  return (
    <List
      searchText={text}
      onSearchTextChange={setText}
      filtering={false}
      searchBarPlaceholder={history.length ? "Ask a follow-up…" : "Ask anything, or tell it to do something…"}
      searchBarAccessory={
        <List.Dropdown tooltip="Screen" value={screenOn ? "on" : "off"} onChange={(v) => setScreenOn(v === "on")}>
          <List.Dropdown.Item title={screenLabel} value="on" icon={Icon.Eye} />
          <List.Dropdown.Item title="Screen off" value="off" icon={Icon.EyeDisabled} />
        </List.Dropdown>
      }
    >
      <List.Section title={history.length ? "Follow-up" : "Quick Ask"}>
        <List.Item
          title={text.trim() || "Type a question or a task"}
          subtitle={text.trim() ? "↵ answer or hand off · ⌘↵ answer here · ⇧⌘↵ T3 thread" : seen ? `${screenLabel}${seen.title ? ` — ${seen.title}` : ""}` : ""}
          icon={Icon.Stars}
          actions={actions}
        />
      </List.Section>
      {history.length > 0 && (
        <List.Section title="This conversation">
          {[...history].reverse().map((t, i) => (
            <List.Item
              key={history.length - i}
              title={t.question}
              subtitle={t.answer.split("\n").find((l) => l.trim()) || ""}
              icon={Icon.Message}
              actions={
                <ActionPanel>
                  <Action.Push title="Show Answer" icon={Icon.Eye} target={<Detail markdown={t.answer} actions={answerActions(t.answer)} />} />
                  <Action.CopyToClipboard title="Copy Answer" content={t.answer} />
                  <Action title="New Conversation" icon={Icon.Plus} shortcut={{ modifiers: ["cmd"], key: "n" }} onAction={() => setHistory([])} />
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}

function Answer(props: { question: string; history: Turn[]; screen: Screen | null; mode: Mode; onDone: (t: Turn) => void }) {
  const { question, history, screen, mode } = props;
  const [text, setText] = useState("");
  const [status, setStatus] = useState<"thinking" | "done" | "handoff" | "error">("thinking");
  const [note, setNote] = useState("");
  const { pop } = useNavigation();
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const ctrl = new AbortController();
    ask({ question, history, screen, allowHandoff: mode === "auto", signal: ctrl.signal, onText: setText })
      .then(async (full) => {
        const trimmed = full.trim();
        if (mode === "auto" && trimmed.startsWith(HANDOFF)) {
          setStatus("handoff");
          const title = trimmed.slice(HANDOFF.length).split("\n")[0].trim() || question;
          setNote(title);
          await handOff(taskForT3(question, history, screen), title);
          return;
        }
        setStatus("done");
        props.onDone({ question, answer: full });
      })
      .catch((e: Error) => {
        if (e.name === "AbortError") return;
        setStatus("error");
        setNote(e.message);
      });
    return () => ctrl.abort();
  }, []);

  // Hide the routing marker while it streams in.
  const routing = mode === "auto" && (HANDOFF.startsWith(text.trim()) || text.trim().startsWith(HANDOFF));
  let body: string;
  if (status === "error") body = `**Couldn't get an answer.**\n\n\`${note}\``;
  else if (status === "handoff") body = `**This is real work, so it's going to T3 Code.**\n\nStarting a thread: _${note}_`;
  else if (!text || routing) body = "_Thinking…_";
  else body = text;

  return (
    <Detail
      isLoading={status === "thinking" || status === "handoff"}
      markdown={`### ${question}\n\n${body}`}
      actions={
        <ActionPanel>
          <Action title="Ask a Follow-Up" icon={Icon.Reply} onAction={pop} />
          {text && !routing && <Action.CopyToClipboard title="Copy Answer" content={text} />}
          {text && !routing && <Action.Paste title="Paste Answer" content={text} shortcut={{ modifiers: ["cmd", "shift"], key: "v" }} />}
          <Action
            title="Continue in T3 Code"
            icon={Icon.Terminal}
            shortcut={{ modifiers: ["cmd"], key: "t" }}
            onAction={() => handOff(taskForT3(question, history, screen), question)}
          />
        </ActionPanel>
      }
    />
  );
}

function answerActions(answer: string) {
  return (
    <ActionPanel>
      <Action.CopyToClipboard title="Copy Answer" content={answer} />
      <Action.Paste title="Paste Answer" content={answer} shortcut={{ modifiers: ["cmd", "shift"], key: "v" }} />
    </ActionPanel>
  );
}

async function handOff(task: string, title: string) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Starting T3 thread…" });
  try {
    await startT3Thread(task, { title });
    await closeMainWindow();
    await popToRoot();
    await showHUD("Started in T3 Code");
  } catch (e) {
    toast.style = Toast.Style.Failure;
    toast.title = "Couldn't start a T3 thread";
    toast.message = e instanceof Error ? e.message : String(e);
  }
}
