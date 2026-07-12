import { createFileRoute, Link } from "@tanstack/react-router";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_shell/styleguide")({
  component: StyleguidePage,
});

// Literal class names so Tailwind's scanner sees every status utility.
const STATUSES = [
  { label: "working", dot: "bg-status-working", text: "text-status-working" },
  { label: "waiting", dot: "bg-status-waiting", text: "text-status-waiting" },
  { label: "failed", dot: "bg-status-failed", text: "text-status-failed" },
  { label: "done", dot: "bg-status-done", text: "text-status-done" },
  { label: "idle", dot: "bg-status-idle", text: "text-status-idle" },
  { label: "offline", dot: "bg-status-offline", text: "text-status-offline" },
];

function StyleguidePage() {
  return (
    <div className="flex items-center justify-center p-6">
      <div className="flex w-full max-w-lg flex-col items-center gap-8 text-center">
        <div>
          <h1 className="text-4xl font-semibold tracking-tight">argus</h1>
          <div className="mt-4 flex justify-center gap-4">
            <Link
              to="/projects"
              className="inline-block text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
            >
              View projects
            </Link>
            <Link
              to="/runs"
              className="inline-block text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
            >
              View runs
            </Link>
          </div>
        </div>

        {/* Design-system smoke test: shadcn primitives skinned by the argus
            tokens. Placeholder until the first real screens land. */}
        <Tabs defaultValue="tokens" className="w-full">
          <TabsList className="self-center">
            <TabsTrigger value="tokens">Tokens</TabsTrigger>
            <TabsTrigger value="controls">Controls</TabsTrigger>
          </TabsList>
          <TabsContent value="tokens">
            <div className="flex flex-col gap-4">
              <div className="flex flex-wrap justify-center gap-x-4 gap-y-2">
                {STATUSES.map((status) => (
                  <span
                    key={status.label}
                    className={cn("inline-flex items-center gap-2 font-mono text-xs", status.text)}
                  >
                    <span className={cn("size-2 rounded-full", status.dot)} />
                    {status.label}
                  </span>
                ))}
              </div>
              {/* The amber group-panel recipe: waiting hue at /7 bg, /20 border. */}
              <div className="rounded-xl border border-status-waiting/20 bg-status-waiting/7 p-1 text-left">
                <div className="px-3 py-2 text-xs font-semibold tracking-wider text-status-waiting">
                  NEEDS YOU · 1
                </div>
                <div className="rounded-lg bg-popover p-3 text-sm font-medium text-popover-foreground">
                  Plan review — export pipeline to streaming
                  <div className="mt-1 font-mono text-xs font-normal text-muted-foreground">
                    quill · export-pipeline · atlas · 4m
                  </div>
                </div>
              </div>
            </div>
          </TabsContent>
          <TabsContent value="controls">
            <div className="flex flex-col gap-4 rounded-xl bg-card p-4">
              <div className="flex flex-wrap justify-center gap-2">
                <Button>Approve — just once</Button>
                <Button variant="secondary">This thread</Button>
                <Button variant="outline">Reject</Button>
                <Button variant="destructive">Revoke</Button>
              </div>
              <div className="flex flex-wrap justify-center gap-2">
                <Badge>3</Badge>
                <Badge variant="secondary">cron</Badge>
                <Badge variant="outline">CLI</Badge>
              </div>
            </div>
          </TabsContent>
        </Tabs>
      </div>
    </div>
  );
}
