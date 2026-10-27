# AgentForge - Platform Artifact Research

## Objective
Research the artifact formats used by Claude Code
and OpenAI Codex.

## Claude Code
- CLAUDE.md: Project instructions.
- .claude/settings.json: Configuration and permissions.

## OpenAI Codex
- AGENTS.md: Project instructions.
- .codex/config.toml: Project-level configuration.

## AgentForge Integration
AgentForge will convert a common AgentSpec
into platform-specific configuration files.

## Next Steps
- Compare Claude Code and Codex formats.
- Document supported configuration fields.
- Define compiler output requirements.
- Test generated artifacts.
## Platform Comparison

| Feature | Claude Code | Codex |
|---------|-------------|-------|
| Instructions | CLAUDE.md | AGENTS.md |
| Configuration | settings.json | config.toml |
| Config Format | JSON | TOML |
| Developer | Anthropic | OpenAI |

## Compiler Requirements

The AgentForge compiler should:

1. Accept a validated AgentSpec.
2. Identify the target platform.
3. Generate the required instruction files.
4. Generate supported configuration files.
5. Return the generated artifacts.
6. Report unsupported settings clearly.
## Compiler Design Decision

AgentForge will use a common AgentSpec
and separate platform-specific compilers.

Each compiler will:
- Read the AgentSpec.
- Generate instruction artifacts.
- Map supported configuration fields.
- Report unsupported fields.
## Subagents and Custom Commands

### Claude Code Subagents

Claude Code supports specialized subagents.

Project-level subagent definitions can be stored in:

.claude/agents/<agent-name>.md

A subagent definition can include:
- Name and description
- Specialized instructions
- Tool access configuration
- Model selection

### Claude Code Skills and Commands

Claude Code supports reusable skills.

Project skills can be stored in:

.claude/skills/<skill-name>/SKILL.md

Skills can define repeatable workflows and may be
invoked through slash commands.

### OpenAI Codex Skills

Codex supports reusable agent skills.

A skill includes a SKILL.md file containing
instructions and metadata.

Skills and Claude Code subagents are not
equivalent features.

## Permissions and Autonomy

### Claude Code

Claude Code uses settings.json for configuration.

Permission rules may include:
- allow
- ask
- deny

### OpenAI Codex

Codex uses config.toml for configuration.

Important settings include:
- approval_policy
- sandbox_mode

These settings control approval behavior
and execution restrictions.

## AgentForge Compiler Implications

1. Generate platform-specific instruction files.
2. Generate supported configuration files.
3. Generate skills or subagents only when supported.
4. Avoid assuming identical permission models.
5. Report unsupported features as warnings.
6. Validate generated artifacts before deployment.

## Official Documentation

Research review date: 2026-10-20

### Claude Code

https://code.claude.com/docs/en/sub-agents

https://code.claude.com/docs/en/skills

https://code.claude.com/docs/en/settings

### OpenAI Codex

https://developers.openai.com/codex/skills

https://developers.openai.com/codex/config/

## Artifact Mapping

| AgentSpec Field | Claude Code | Codex |
|---|---|---|
| name | CLAUDE.md heading | AGENTS.md heading |
| description | CLAUDE.md | AGENTS.md |
| instructions | CLAUDE.md | AGENTS.md |
| coding_rules | CLAUDE.md | AGENTS.md |
| testing_rules | CLAUDE.md | AGENTS.md |
| permissions | settings.json | Platform-specific mapping |
| autonomy | Platform-specific mapping | config.toml |
| skills | SKILL.md | SKILL.md |
| subagents | Agent definitions | Requires investigation |

## Mapping Notes

1. AgentSpec field names are proposed.
2. Both platforms support project instructions.
3. Configuration formats differ.
4. Permission models are not identical.
5. Skills may require different output directories.
6. Unsupported features must produce warnings.
7. Exact mappings require validation.

## Unknowns and Open Questions

1. What is the final AgentSpec schema?
   Status: Pending backend team agreement.

2. How should Claude Code tool permissions
   map to Codex approval and sandbox settings?
   Status: No exact one-to-one mapping confirmed.

3. Which subagent features can be represented
   across both platforms?
   Status: Requires platform-specific validation.

4. Which command and skill features should
   AgentForge support in its MVP?
   Status: Pending scope decision.

5. Do the generated artifacts work in real
   Claude Code and Codex sessions?
   Status: Not tested yet.

## Final Research Summary

### Findings

- Claude Code uses CLAUDE.md for project instructions.
- Codex uses AGENTS.md for repository instructions.
- Claude Code supports JSON-based settings.
- Codex supports TOML-based configuration.
- Both platforms support reusable skills.
- Permissions and autonomy require separate mappings.

### Compiler Design Decision

AgentForge should use a common AgentSpec
and separate platform-specific compilers.

Each compiler should:
- Read a validated AgentSpec.
- Generate supported artifacts.
- Map platform-specific configuration.
- Report unsupported fields.
- Validate generated output.

## Acceptance Criteria Checklist

Research review date: 2026-10-20

- [x] Identify instruction artifact formats.
- [x] Identify configuration artifact formats.
- [x] Document candidate AgentSpec mappings.
- [x] Record official documentation references.
- [x] Flag unknowns and limitations.
- [ ] Complete official documentation verification.
- [ ] Perform runtime validation.

## Final Review Notes

### Important Limitations

- AgentSpec field names are not finalized.
- Claude Code and Codex permissions are not identical.
- Subagents require platform-specific handling.
- Model availability must be verified.
- Example files have not been runtime-tested.

### Acceptance Criteria Assessment

- Artifact formats: Documented at research level.
- Official references: Included for follow-up verification.
- Mapping candidates: Listed.
- Unknowns: Explicitly flagged.
- Runtime validation: Pending a separate task.