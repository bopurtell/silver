# Manage This Project…

Choose **Project ▾ → Manage This Project…** or search for it in the palette.
Silver opens a centered window over the workspace you're inspecting. At
80 columns it uses nearly the whole width, with Objects above Actions. On
wider terminals the two lists sit side by side.

To copy a profile, select it under its chip and flow, then choose **Duplicate
Profile…**. For a chip other than your current launch target, **Browse flows
and profiles…** reads that chip's catalog. Browsing and authoring do not select
the chip for launch or replace a staged plan.

You can click objects and actions, or use **Tab/Shift-Tab** between the lists,
**↑/↓** or counted **j/k** within a list, and **/** to filter. Shortcut hints
are hidden by default; click **Filter** or press **/** to start typing.
To see the shortcuts, open the command palette (**Space c c**) and choose
**Show project browser control hints**. Choose **Hide project browser control
hints** to turn them off again. Silver remembers this preference.

**Enter** on an object moves to its actions. When you finish or cancel a wizard opened here,
you return to the same object and can manage something else. Dismiss the
browser to resume your original inspection. A wizard opened directly from
the palette doesn't take you through the browser.

## Why a window

The WB-086 trial compared a full-screen project workspace with a narrow side
window. Both kept launch intent independent of browsing. The workspace
accommodated longer paths; the side window kept part of Testing visible but
left only 42 columns for managing objects. The owner chose a large centered
window to keep that inspection context without sacrificing readable paths.
The separate workspace and trial host switch are retired.

The original 80-column comparisons covered module creation, chip preview and
cancel, browsing another chip while FIFO had a staged plan, and keeping an
active Testing job running. Historical captures are under
`~/.cache/wb086-real-03/{workspace,window}/` on the trial machine.
