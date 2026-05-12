"""
OpenAI Agents SDK + Microsoft Learn MCP via Agentgateway
========================================================

This script validates the end-to-end path:

    OpenAI Agents SDK (Agent + Runner)
        |
        v
    MCPServerStreamableHttp -> http://localhost:8080/mcp-mslearn  (port-forward)
        |
        v
    agentgateway proxy (Service in agentgateway-system)
        |
        v
    AgentgatewayBackend "mslearn-mcp-backend"
        |
        v
    https://learn.microsoft.com/api/mcp  (Microsoft Learn MCP, public, anonymous)

Prerequisites
-------------
1. The lab cluster is up with setup.sh INSTALL_AGENTGATEWAY=true (the default).
2. A port-forward is running in another terminal:

       kubectl -n agentgateway-system port-forward \
           deployment/agentgateway-proxy 8080:80

3. OPENAI_API_KEY is exported in your shell.
4. openai-agents is installed:

       pip install --upgrade openai-agents

Usage
-----
    python3 test-mslearn-agent.py

This runs a single agent turn asking about Azure App Service. The agent
will call Microsoft Learn MCP tools (e.g. docs search / fetch) via
agentgateway and incorporate the results into its answer.
"""

from __future__ import annotations

import asyncio
import os
import sys

from agents import Agent, Runner
from agents.mcp import MCPServerStreamableHttp


# URL of the agentgateway proxy listener (matches the HTTPRoute path prefix
# /mcp-mslearn that setup.sh creates).
AGENTGATEWAY_URL = os.environ.get(
    "AGENTGATEWAY_URL",
    "http://localhost:8080/mcp-mslearn",
)

# The model used by the Agent. Override with OPENAI_MODEL if you want a
# cheaper/faster or a stronger model.
MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")


async def main() -> int:
    if "OPENAI_API_KEY" not in os.environ:
        print(
            "error: OPENAI_API_KEY is not set. Export it before running this script.",
            file=sys.stderr,
        )
        return 2

    print(f"Connecting to Microsoft Learn MCP via {AGENTGATEWAY_URL}", file=sys.stderr)

    async with MCPServerStreamableHttp(
        name="Microsoft Learn Docs",
        params={
            "url": AGENTGATEWAY_URL,
            "timeout": 30,
        },
        cache_tools_list=True,
    ) as mcp_server:
        # List the tools the gateway exposes so we see what the agent has access to.
        tools = await mcp_server.list_tools()
        print(
            "Tools exposed by Microsoft Learn MCP (via agentgateway): "
            + ", ".join(t.name for t in tools),
            file=sys.stderr,
        )

        agent = Agent(
            name="Microsoft docs assistant",
            instructions=(
                "You are an assistant that answers questions about Microsoft "
                "technologies. Always use the Microsoft Learn MCP tools to "
                "search the official documentation before answering. When you "
                "use information from a doc, cite its URL."
            ),
            model=MODEL,
            mcp_servers=[mcp_server],
        )

        prompt = (
            "What is Azure App Service, what programming languages does it "
            "support, and what is the difference between an App Service Plan "
            "and an App Service? Search the Microsoft Learn docs and cite "
            "the URLs you used."
        )

        result = await Runner.run(agent, prompt)
        print()
        print("=" * 80)
        print("Agent final answer:")
        print("=" * 80)
        print(result.final_output)

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
