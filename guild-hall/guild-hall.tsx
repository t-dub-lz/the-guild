#!/usr/bin/env bun
import React, { useState, useEffect } from "react";
import { render, Box, Text, useApp, useStdout } from "ink";

import { TabBar, TabName, useTabNavigation } from "./components/TabBar";
import { Footer } from "./components/Footer";
import { NewRunForm, FormState, MEMBER_LIST } from "./components/NewRun/NewRunForm";
import { Dashboard } from "./components/Current/Dashboard";
import { MemberCards } from "./components/Current/MemberCards";
import { LiveLog } from "./components/Current/LiveLog";
import { RunList } from "./components/History/RunList";
import { RunDetail } from "./components/History/RunDetail";
import { useKeys } from "./hooks/useKeys";
import { useDatabase, ConclaveRun } from "./hooks/useDatabase";
import { useProcess, RunOptions } from "./hooks/useProcess";

import defaults from "./defaults.json";

function App() {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [activeTab, setActiveTab] = useState<TabName>("new-run");
  const { goLeft, goRight, goToTab } = useTabNavigation(activeTab, setActiveTab);

  // Terminal dimensions (with resize handling)
  const [termSize, setTermSize] = useState({ cols: stdout.columns, rows: stdout.rows });

  useEffect(() => {
    const onResize = () => {
      setTermSize({ cols: stdout.columns, rows: stdout.rows });
    };
    stdout.on("resize", onResize);
    return () => {
      stdout.off("resize", onResize);
    };
  }, [stdout]);

  // Database
  const db = useDatabase();
  const [runCount, setRunCount] = useState(0);
  const [runs, setRuns] = useState<ConclaveRun[]>([]);

  // History state
  const [historyIndex, setHistoryIndex] = useState(0);
  const [selectedRun, setSelectedRun] = useState<ConclaveRun | null>(null);
  const [memberIndex, setMemberIndex] = useState(0);

  // Form editing state (to disable global keys during text input)
  const [isEditing, setIsEditing] = useState(false);

  // New Run form state (lifted here so it persists across tab switches)
  const [formState, setFormState] = useState<FormState>(() => ({
    org: defaults.org,
    repoMode: "all",
    members: Object.fromEntries(
      MEMBER_LIST.map((m) => [m.id, defaults.members.includes(m.id)])
    ),
    strict: defaults.strict,
    superStrict: defaults.superStrict,
    scanAll: defaults.scanAll,
    dryRun: defaults.dryRun,
    parallelism: defaults.parallelism,
  }));

  // Process state
  const process = useProcess();

  // Load initial data
  useEffect(() => {
    setRunCount(db.countRuns());
    setRuns(db.listRuns());
  }, []);

  // Poll during active run
  useEffect(() => {
    if (!process.running) return;

    const interval = setInterval(() => {
      setRuns(db.listRuns());
      setRunCount(db.countRuns());
    }, defaults.ui.pollIntervalMs);

    return () => clearInterval(interval);
  }, [process.running]);

  // Global key handling - active when not editing text fields
  useKeys((key) => {
    // Allow quit (but not during text input)
    if (key === "q") {
      exit();
    } else if (key === "tab") {
      goRight(); // Tab cycles forward through tabs
    } else if (key === "backtab") {
      goLeft(); // Shift+Tab cycles backward
    }
  }, !isEditing); // Disabled during text editing

  // Tab navigation with h/l - disabled when on new-run (form uses h/l for members)
  useKeys((key) => {
    if (key === "left") {
      goLeft();
    } else if (key === "right") {
      goRight();
    } else if (key === "escape" && selectedRun) {
      setSelectedRun(null);
    }
  }, activeTab !== "new-run");

  // Current tab - cancel scan with 'c'
  useKeys((key) => {
    if (key === "c" && process.running) {
      process.stop();
    }
  }, activeTab === "current");

  // History navigation
  useKeys((key) => {
    if (selectedRun) {
      // Detail view navigation
      if (key === "down") {
        setMemberIndex((i) => Math.min(i + 1, 4));
      } else if (key === "up") {
        setMemberIndex((i) => Math.max(i - 1, 0));
      } else if (key === "backspace" || key === "escape") {
        setSelectedRun(null);
      }
    } else {
      // List view navigation
      if (key === "down") {
        setHistoryIndex((i) => Math.min(i + 1, runs.length - 1));
      } else if (key === "up") {
        setHistoryIndex((i) => Math.max(i - 1, 0));
      } else if (key === "return" && runs[historyIndex]) {
        setSelectedRun(runs[historyIndex]);
        setMemberIndex(0);
      } else if (key === "g") {
        setHistoryIndex(0);
      } else if (key === "G") {
        setHistoryIndex(runs.length - 1);
      }
    }
  }, activeTab === "history");

  const handleNewRun = (formState: any) => {
    const options: RunOptions = {
      org: formState.org,
      members: Object.entries(formState.members)
        .filter(([, v]) => v)
        .map(([k]) => k),
      parallelism: formState.parallelism,
      strict: formState.strict,
      superStrict: formState.superStrict,
      scanAll: formState.scanAll,
      dryRun: formState.dryRun,
    };
    process.start(options);
    setActiveTab("current");
  };

  // Footer hints based on context
  const getHints = () => {
    if (activeTab === "new-run") {
      return "↑/k ↓/j:fields  ←/h →/l:options  Space:toggle  i/Enter:edit  Tab:tabs  q:quit";
    } else if (activeTab === "current") {
      if (process.running) {
        return "↑/k ↓/j:select member  c:cancel scan  Tab:switch tabs  q:quit";
      }
      return "Tab:switch tabs  q:quit";
    } else if (activeTab === "history") {
      if (selectedRun) {
        return "↑/k ↓/j:select  Enter:view findings  Esc:back  Tab:switch tabs  q:quit";
      }
      return "↑/k ↓/j:navigate  Enter:view details  g/G:top/bottom  Tab:switch tabs  q:quit";
    }
    return "";
  };

  // Member data for current run - filtered to only show selected members
  const allMemberStatuses = [
    { id: "ascii-cutterman", name: "ASCII Cutterman", progress: 0, findings: 0, complete: false },
    { id: "secretary", name: "Secretary", progress: 0, findings: 0, complete: false },
    { id: "sentinel", name: "Sentinel", progress: 0, findings: 0, complete: false },
    { id: "catburglar", name: "Catburglar", progress: 0, findings: 0, complete: false },
    { id: "the-judge", name: "The Judge", progress: 0, findings: 0, complete: false },
  ];
  const memberStatuses = allMemberStatuses.filter((m) => formState.members[m.id]);

  // Placeholder member summaries for history detail
  const memberSummaries = [
    { id: "ascii-cutterman", name: "ASCII Cutterman", issues: 0 },
    { id: "secretary", name: "Secretary", issues: 0 },
    { id: "sentinel", name: "Sentinel", issues: 0 },
    { id: "catburglar", name: "Catburglar", issues: 0 },
    { id: "the-judge", name: "The Judge", issues: 0 },
  ];

  return (
    <Box flexDirection="column" width={termSize.cols} height={termSize.rows}>
      <TabBar
        activeTab={activeTab}
        onTabChange={setActiveTab}
        isRunning={process.running}
      />

      <Box flexGrow={1} flexDirection="column">
        {activeTab === "new-run" && (
          <NewRunForm
            form={formState}
            onFormChange={setFormState}
            onSubmit={handleNewRun}
            active={activeTab === "new-run"}
            onEditingChange={setIsEditing}
          />
        )}

        {activeTab === "current" && (
          <>
            {process.running ? (
              <>
                <Dashboard
                  progress={0}
                  reposCompleted={0}
                  reposTotal={0}
                  filesScanned={0}
                  issueCount={0}
                />
                <Box flexGrow={1} overflow="hidden">
                  <LiveLog lines={process.output} maxWidth={Math.floor(termSize.cols / 2) - 4} />
                  <MemberCards
                    members={memberStatuses}
                    selectedIndex={0}
                    focused={false}
                  />
                </Box>
              </>
            ) : (
              <Box padding={1} flexDirection="column">
                <Text dimColor>No active scan</Text>
                <Text dimColor>Go to New Run tab to start a scan</Text>
              </Box>
            )}
          </>
        )}

        {activeTab === "history" && (
          <>
            {selectedRun ? (
              <RunDetail
                run={selectedRun}
                memberSummaries={memberSummaries}
                selectedMemberIndex={memberIndex}
                focused={true}
                onBack={() => setSelectedRun(null)}
              />
            ) : (
              <RunList
                runs={runs}
                selectedIndex={historyIndex}
                focused={true}
                onSelect={setSelectedRun}
              />
            )}
          </>
        )}
      </Box>

      <Footer
        hints={getHints()}
        runCount={runCount}
        org={defaults.org || undefined}
        status={process.running ? "Running..." : undefined}
      />
    </Box>
  );
}

render(<App />);
