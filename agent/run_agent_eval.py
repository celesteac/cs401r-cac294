"""
Run the Track C evaluation scenarios against the deployed AgentCore harness.

    python agent/run_agent_eval.py --runs 2          # from the repo root

Each run evaluates every scenario in evaluation_harness.AGENT_TEST_CASES (the
five required ones plus the bonus prompt-injection case), each in its own
runtime session, through harness_client.HarnessAgent. That client appends every
tool call to docs/lab3-evidence/agent-traces.jsonl and one cost row per session
to docs/lab3-evidence/agent-cost.csv.

Writes one CSV per run to evaluation_results/ (agent_eval_<label>_<timestamp>.csv)
with the scenario verdicts plus the session_id, so a failure can be traced back
to its rows in agent-traces.jsonl. Copy the final one to
docs/lab3-evidence/agent_eval.csv.
"""
import argparse
import os
import sys
from datetime import datetime, timezone

import pandas as pd

# Run as a script from the repo root: make `evaluation_harness` and `agent.*`
# importable regardless of which directory Python put on sys.path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import evaluation_harness as eh  # noqa: E402
from agent.harness_client import HarnessAgent  # noqa: E402


def run_once(label: str) -> pd.DataFrame:
    agent = HarnessAgent(run_label=label)
    evaluator = eh.LocalAgentEvaluator(invoke_fn=agent.invoke)
    rows = []
    for tc in eh.AGENT_TEST_CASES:
        print(f"  [{label}] {tc.scenario_id} ({tc.scenario_type}) ...", flush=True)
        result = evaluator.evaluate_scenario(tc)
        result["run"] = label
        result["session_id"] = agent.last_session_id
        rows.append(result)
        print(f"    {'PASS' if result['passed'] else 'FAIL'}  tools={result['tool_calls']}  "
              f"escalated={result['escalated']} (expected {result['escalation_expected']})", flush=True)
    return pd.DataFrame(rows)


def main():
    ap = argparse.ArgumentParser(description="Run the Track C agent evaluation")
    ap.add_argument("--runs", type=int, default=2, help="Independent runs of all scenarios")
    ap.add_argument("--label-prefix", default="eval", help="Run labels are <prefix>-1, <prefix>-2, ...")
    ap.add_argument("--output-dir", default="evaluation_results")
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for i in range(1, args.runs + 1):
        label = f"{args.label_prefix}-{i}"
        df = run_once(label)
        path = os.path.join(args.output_dir, f"agent_eval_{label}_{stamp}.csv")
        df.to_csv(path, index=False)
        print(f"  {label}: {int(df['passed'].sum())}/{len(df)} passed -> {path}\n", flush=True)


if __name__ == "__main__":
    main()
