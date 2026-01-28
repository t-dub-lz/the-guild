#!/usr/bin/env bun
import React, { useState, useEffect } from "react";
import { render, Box, Text, useApp } from "ink";

import { TabBar, TabName, useTabNavigation } from "./components/TabBar";
import { Footer } from "./components/Footer";
import { NewRunForm } from "./components/NewRun/NewRunForm";
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
  const [activeTab, setActiveTab] = useState<TabName>("new-run");
  const { goLeft, goRight, goToTab } = useTabNavigation(activeTab, setActiveTab);

  // Database
  const db = useDatabase();
  const [runCount, setRunCount] = useState(0);
  const [runs, setRuns] = useState<ConclaveRun[]>([]);

  // History state
  const [historyIndex, setHistoryIndex] = useState(0);
  const [selectedRun, setSelectedRun] = useState<ConclaveRun | null>(null);
  const [memberIndex, setMemberIndex] = useState(0);

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

  // Global key handling
  useKeys((key) => {
    if (key === "q") {
      exit();
    } else if (key === "left") {
      goLeft();
    } else if (key === "right") {
      goRight();
    } else if (key === "1") {
      goToTab(1);
    } else if (key === "2") {
      goToTab(2);
    } else if (key === "3") {
      goToTab(3);
    } else if (key === "escape" && selectedRun) {
      setSelectedRun(null);
    }
  }, activeTab !== "new-run"); // Disable when form is active

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
      return "↑/k ↓/j:move  Space:toggle  Enter:activate  Tab:section";
    } else if (activeTab === "current") {
      return "↑/k ↓/j:select member  Enter:view findings  Esc:back";
    } else if (activeTab === "history") {
      if (selectedRun) {
        return "↑/k ↓/j:select  Enter:view findings  Esc/Backspace:back";
      }
      return "↑/k ↓/j:navigate  Enter:view details  g/G:top/bottom";
    }
    return "";
  };

  // Placeholder member data for current run
  const memberStatuses = [
    { id: "ascii-cutterman", name: "ASCII Cutterman", progress: 0, findings: 0, complete: false },
    { id: "secretary", name: "Secretary", progress: 0, findings: 0, complete: false },
    { id: "sentinel", name: "Sentinel", progress: 0, findings: 0, complete: false },
    { id: "catburglar", name: "Catburglar", progress: 0, findings: 0, complete: false },
    { id: "the-judge", name: "The Judge", progress: 0, findings: 0, complete: false },
  ];

  // Placeholder member summaries for history detail
  const memberSummaries = [
    { id: "ascii-cutterman", name: "ASCII Cutterman", issues: 0 },
    { id: "secretary", name: "Secretary", issues: 0 },
    { id: "sentinel", name: "Sentinel", issues: 0 },
    { id: "catburglar", name: "Catburglar", issues: 0 },
    { id: "the-judge", name: "The Judge", issues: 0 },
  ];

  return (
    <Box flexDirection="column" height="100%">
      <TabBar
        activeTab={activeTab}
        onTabChange={setActiveTab}
        isRunning={process.running}
      />

      <Box flexGrow={1} flexDirection="column">
        {activeTab === "new-run" && (
          <NewRunForm
            defaults={defaults}
            onSubmit={handleNewRun}
            active={activeTab === "new-run"}
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
                <Box flexGrow={1}>
                  <MemberCards
                    members={memberStatuses}
                    selectedIndex={0}
                    focused={false}
                  />
                  <LiveLog lines={process.output} />
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
