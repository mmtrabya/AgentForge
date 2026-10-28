import re
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        strict=True,
    )


class ProjectSpec(StrictModel):
    name: str = Field(min_length=1)
    description: str | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Project name cannot be blank")
        return value


class ToolSpec(StrictModel):
    name: str = Field(min_length=1)
    description: str | None = None
    enabled: bool = True

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Tool name cannot be blank")
        return value


class ConstraintsSpec(StrictModel):
    rules: list[str] = Field(default_factory=list)


class WorkflowSpec(StrictModel):
    steps: list[str] = Field(default_factory=list)


class QualitySpec(StrictModel):
    criteria: list[str] = Field(default_factory=list)


class AutonomySpec(StrictModel):
    level: Literal["low", "medium", "high"] = "medium"


class AgentSpec(StrictModel):
    name: str = Field(min_length=1)
    description: str | None = None
    runtime: Literal["python", "node", "container"]
    entrypoint: str = Field(min_length=1)
    tools: list[str] = Field(default_factory=list)
    environment: dict[str, str] = Field(default_factory=dict)
    config: dict[str, Any] = Field(default_factory=dict)

    constraints: ConstraintsSpec = Field(default_factory=ConstraintsSpec)
    workflow: WorkflowSpec = Field(default_factory=WorkflowSpec)
    quality: QualitySpec = Field(default_factory=QualitySpec)
    autonomy: AutonomySpec = Field(default_factory=AutonomySpec)

    @field_validator("name", "entrypoint")
    @classmethod
    def validate_non_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Value cannot be blank")
        return value

    @field_validator("tools")
    @classmethod
    def validate_unique_tools(cls, value: list[str]) -> list[str]:
        if len(value) != len(set(value)):
            raise ValueError("Tool names must not contain duplicates")
        if any(not tool.strip() for tool in value):
            raise ValueError("Tool names cannot be blank")
        return value

    @field_validator("environment")
    @classmethod
    def validate_environment_names(
        cls, value: dict[str, str]
    ) -> dict[str, str]:
        for name in value:
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                raise ValueError(
                    f"Invalid environment variable name: {name}"
                )
        return value


class AgentDefinition(StrictModel):
    agent: AgentSpec
    project: ProjectSpec
    tools: list[ToolSpec] = Field(default_factory=list)