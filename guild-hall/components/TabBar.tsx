// guild-hall/components/TabBar.tsx
import React from "react";
import { Box, Text } from "ink";

export type TabName = "new-run" | "current" | "history";

interface Tab {
  id: TabName;
  label: string;
}

const TABS: Tab[] = [
  { id: "new-run", label: "New Run" },
  { id: "current", label: "Current" },
  { id: "history", label: "History" },
];

interface TabBarProps {
  activeTab: TabName;
  onTabChange: (tab: TabName) => void;
  isRunning?: boolean;
}

export function TabBar({ activeTab, onTabChange, isRunning }: TabBarProps) {
  return (
    <Box
      borderStyle="single"
      borderTop={false}
      borderLeft={false}
      borderRight={false}
      paddingX={1}
      gap={2}
    >
      {TABS.map((tab) => {
        const isActive = tab.id === activeTab;
        const showIndicator = tab.id === "current" && isRunning;

        return (
          <Box key={tab.id}>
            <Text bold={isActive} inverse={isActive}>
              {isActive ? " ⚔️ " : "  "}
              {tab.label}
              {showIndicator ? " ●" : ""}
              {"  "}
            </Text>
          </Box>
        );
      })}
    </Box>
  );
}

export function useTabNavigation(
  activeTab: TabName,
  setActiveTab: (tab: TabName) => void
) {
  const tabOrder: TabName[] = ["new-run", "current", "history"];
  const currentIndex = tabOrder.indexOf(activeTab);

  const goLeft = () => {
    const newIndex = currentIndex > 0 ? currentIndex - 1 : tabOrder.length - 1;
    setActiveTab(tabOrder[newIndex]);
  };

  const goRight = () => {
    const newIndex = currentIndex < tabOrder.length - 1 ? currentIndex + 1 : 0;
    setActiveTab(tabOrder[newIndex]);
  };

  const goToTab = (num: number) => {
    if (num >= 1 && num <= tabOrder.length) {
      setActiveTab(tabOrder[num - 1]);
    }
  };

  return { goLeft, goRight, goToTab };
}
