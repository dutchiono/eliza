# Eliza Home "Normal People + Family Secretary" Product Plan (Build-Gated + Food for Thought)

## Summary

Create a product/implementation planning doc focused on making Eliza usable for mainstream households.

This plan is explicitly build-gated: no feature execution until Home desktop build/release is consistently green.

V1 priority is onboarding-first, with heartbeat concepts hidden from default UX and a clear path to family organizer workflows.

## Food for Thought: Product Lens for Developers

This document is not only an implementation plan. It is also a thinking aid for building Eliza as a life utility, not just a feature set.

As you design and ship, pressure-test decisions against this question:

`Does this make family life meaningfully easier for non-technical people in under five minutes?`

## Food for Thought: Questions to Ask Before Building

- Is this reducing cognitive load for the household organizer, or adding new setup/admin burden?
- Does the user understand what Eliza is doing without technical language?
- Can a parent explain this feature to a child in plain words?
- If this fails, does the user know what happened and what to do next?
- Are we optimizing for real household routines (school, appointments, logistics), not just demo flows?
- Does this respect family trust boundaries by default?
- If budget is tight, does this still feel useful?

## Food for Thought: Everyday Life Scenarios

- "School morning chaos": Can Eliza summarize today's schedule and missing prep items quickly?
- "Split household planning": Can two guardians coordinate calendar/email tasks without duplicated effort?
- "Kid asks for help": Can a child use Eliza safely within parent-set budget/permission limits?
- "Low-budget month": Can the family still get reliable value with strict quota and throttled usage?
- "Travel week": Can Eliza proactively surface conflicts, reminders, and follow-ups with minimal prompting?

## Implementation Changes

### 1) Phase 0: Build Stability Gate (Must pass first)

- Define an explicit release gate for Home: CI green on lint/build/test plus 4-platform Electrobun matrix plus smoke checks.
- Freeze net-new product work until gate is green on at least 2 consecutive runs.
- Keep this gate documented as the blocker condition at top of this document.

### 2) Phase 1: "Normal User" Onboarding (Desktop/Web first)

- Replace technical language in onboarding (especially "heartbeats") with plain-language assistant setup concepts.
- Add guided setup steps:
  - Choose assistant mode (`Personal`, `Family Organizer`)
  - Pick model provider (`Eliza Cloud` recommended; BYO key supported)
  - Connect first capability (calendar or email) with clear permission prompts
- Add a safe-default profile: read-only connectors, explicit opt-in for proactive actions.
- Add post-onboarding "first win" flow (one concrete useful task completed in less than 5 minutes).

### 3) Phase 1: Family Secretary Core (Desktop/Web)

- Introduce Family Workspace concept with roles:
  - Organizer (primary admin)
  - Parent/Guardian (co-admin)
  - Member (child/family participant)
- Start with read-oriented secretary features:
  - Family calendar aggregation and reminders
  - Family message digest/inbox summary
  - Task extraction from connected email/calendar/chat
- Add organizer-relief workflows:
  - Weekly planning brief
  - Conflict detection (time overlap, missing RSVP, missing transport note)
  - Follow-up suggestions with one-tap approval

### 4) Permission + Trust Model (Default)

- Use consent-by-step onboarding:
  - separate grants for email/calendar/chat
  - explicit "what Eliza can read/do"
  - revocation and audit visibility in settings
- Keep initial actions read-only by default; action-taking requires explicit per-capability opt-in.

### 5) Family Cost Controls and Shared LLM Budget (Parent-managed)

- Treat household model spend as a shared budget controlled by Organizer/Parent roles.
- Add per-member usage policies so parents can allocate model usage by percentage or fixed quota.
  - Example policy: child gets 20% of weekly token budget.
- Add throttling and fallback behavior when a child allocation is exhausted:
  - hard stop, slower model tier, or "ask parent for more budget" flow.
- Add parent controls dashboard for:
  - total weekly/monthly token usage
  - per-member usage and remaining allocation
  - forecasted overage risk and policy edits
- Ensure policy enforcement is provider-agnostic (works with Eliza Cloud and BYO key).

### 6) Phase 2 (Defined now, implemented later): Mobile + Child Install

- Add design contracts now, implementation later:
  - guardian-managed child enrollment
  - family-device linking flow
  - limited child profile permissions and visibility rules
- Mobile is a phase gate after desktop/web onboarding plus family workflows prove stable.

## Public Interfaces / Contracts

- User-facing mode contract: onboarding mode selection (`Personal`, `Family Organizer`), no technical heartbeat terminology in default UI.
- Family workspace contract: role model plus membership plus shared calendar/task/digest surface.
- Permissions contract: connector-level grants, human-readable consent text, revoke/audit controls.
- Proactive assistance contract: proactive suggestions by default; autonomous actions only with explicit opt-in.
- Cost-control contract: parent-managed household quota plus per-member allocation plus enforced throttling/fallback policies.

## Test Plan

- Build gate tests:
  - Existing Home CI/release/smoke gates pass consistently across platforms.
- Onboarding UX tests:
  - New user completes setup without editing files.
  - Time-to-first-useful-task metric and completion rate.
  - Terminology comprehension test (no "heartbeat" confusion in default flow).
- Family workflow tests:
  - Calendar/event ingestion and summary generation.
  - Conflict detection and reminder accuracy.
  - Role-based visibility and permission boundaries.
- Cost-control tests:
  - Per-member quota enforcement is correct under concurrent usage.
  - Allocation changes take effect immediately without restarting the app.
  - Throttling/fallback behavior triggers predictably at quota thresholds.
  - Dashboard totals match provider-side usage accounting.
- Safety tests:
  - Permission revoke immediately blocks future reads/actions.
  - Audit trail reflects connector access and action approvals.

## Assumptions and Defaults

- V1 priority: onboarding-first for mainstream users.
- Default trust model: consent-by-step, granular permissions.
- Mobile/child support: Phase 2 gate (contracts now, implementation later).
- Eliza Cloud is recommended during onboarding; BYO model keys remain supported.
