import * as React from "react";

import { cn } from "@/lib/utils";

// Local registry edit (argus badge/tabs precedent): the base-nova registry
// ships `md:text-sm`, which a route-level fine-pointer override cannot
// cancel (different variants never conflict in tailwind-merge) — a
// coarse-pointer landscape phone at md width would compute below 16px and
// re-trigger iOS auto-zoom. The compact size instead rides
// `not-any-pointer-coarse:pointer-fine:text-sm`: BOTH conditions are
// load-bearing — `pointer` describes only the PRIMARY device, so a hybrid
// laptop with a fine trackpad AND a coarse touchscreen matches
// `pointer-fine:`; `not-any-pointer-coarse:` shrinks text only when NO
// coarse pointer exists at all, keeping 16px on every touch-capable device.
function Textarea({ className, ...props }: React.ComponentProps<"textarea">) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        "flex field-sizing-content min-h-16 w-full rounded-lg border border-input bg-transparent px-2.5 py-2 text-base transition-colors outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:bg-input/50 disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20 not-any-pointer-coarse:pointer-fine:text-sm dark:bg-input/30 dark:disabled:bg-input/80 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40",
        className,
      )}
      {...props}
    />
  );
}

export { Textarea };
