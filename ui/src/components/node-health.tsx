import { StatusDot } from "@/components/system/status-dot";
import type { ShellNode } from "@/lib/shell-data";

// Rail footer node roster. Deviation from the mock's dimmed rows: name and
// meta render in full-opacity text-muted-foreground (11px text needs 4.5:1
// against --sidebar — 4.76:1 light / 5.36:1 dark; the mock's per-row
// dimming would fail that). Offline status stays visible via the hollow dot
// plus the "offline 2h" meta text; online is dot + sr-only copy.
export function NodeHealth({ nodes }: { nodes: ShellNode[] }) {
  return (
    <ul role="list" className="flex flex-col gap-1.5 font-mono text-[11px]">
      {nodes.map((node) => (
        <li key={node.name} className="flex items-center gap-[7px] text-muted-foreground">
          {node.online ? (
            <>
              <StatusDot status="online" size="sm" />
              <span className="sr-only">online</span>
            </>
          ) : (
            <StatusDot status="offline" size="sm" />
          )}
          {node.name}
          <span className="ml-auto">{node.meta}</span>
        </li>
      ))}
    </ul>
  );
}
