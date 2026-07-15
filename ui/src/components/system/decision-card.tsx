import type { ReactNode } from "react";
import { cn } from "@/lib/utils";
import { MetaLine } from "./meta-line";

// The approval-card SHELL (mock 2b approve/question/compact-gate, 4a
// irreversible/expired, 5b desk): invariant chrome + slots. Everything
// below the header — command preview, scope chips, note field, reply row,
// action rows — is slotted `children`, owned by the gate screens (2b),
// which pass real controls. The shell itself renders no focusable control.
// The version chip ("v2 · you") is deferred to the gate screens (3b/4b);
// 2b ships none per the step-5 locked decision.
//
// A11y mirrors GroupPanel's labelled-section rule: with `labelId` the card
// is an <article aria-labelledby>; the CALL SITE owns heading semantics by
// passing a heading element carrying id={labelId} as `title` (the card owns
// the title typography — preflight makes headings inherit). Without labelId
// it stays a plain <div>.
//
// tone "amber" is the pending recipe — mock-exact /30 border in dark; the
// /45 light border derives from GroupPanel's light:dark ratio (no light
// mock evidence — retune in the light check). Irreversible cards keep the
// amber tone (red enters via the icon slot + slotted notice). tone "muted"
// is 4a's expired card: dashed default border, washed surface, no shadow.
// tone "resolved" is 2b's decided-in-place face: neutral border-border +
// bg-card in BOTH modes, no dash, NO opacity anywhere — amber signals
// pending and dashed muted is 4a's expired vocabulary, and the neutral look
// is component vocabulary, not caller knowledge of the shell's internal
// border classes (a caller border-border override would silently lose to
// dark:border-status-waiting/30 under tailwind-merge's same-variant rule).
// The 14px radius is deliberate mock anatomy between lg and xl — don't
// bend it onto the scale.
const TONE_CLASSES: Record<"amber" | "muted" | "resolved", string> = {
  amber:
    "border-status-waiting/45 bg-card shadow-xs dark:border-status-waiting/30 dark:shadow-none",
  muted: "border-dashed bg-card/60 text-muted-foreground",
  resolved: "border-border bg-card",
};

export function DecisionCard({
  tone = "amber",
  icon,
  title,
  labelId,
  meta,
  trailing,
  className,
  children,
}: {
  tone?: "amber" | "muted" | "resolved";
  icon?: ReactNode;
  title: ReactNode;
  labelId?: string;
  meta?: readonly string[];
  trailing?: ReactNode;
  className?: string;
  children?: ReactNode;
}) {
  const Tag = labelId !== undefined ? "article" : "div";
  return (
    <Tag
      data-slot="decision-card"
      data-tone={tone}
      aria-labelledby={labelId}
      className={cn(
        "flex flex-col gap-[11px] rounded-[14px] border p-[13px]",
        TONE_CLASSES[tone],
        className,
      )}
    >
      <div data-slot="decision-card-header" className="flex items-start gap-2.5">
        {icon}
        <div className="min-w-0 flex-1">
          <div className="text-[0.84375rem] leading-[1.4] font-semibold">{title}</div>
          {meta !== undefined && <MetaLine segments={meta} className="mt-0.5" />}
        </div>
        {trailing}
      </div>
      {children}
    </Tag>
  );
}
