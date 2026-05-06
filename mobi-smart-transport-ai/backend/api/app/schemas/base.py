from pydantic import BaseModel, ConfigDict


class StrictApiModel(BaseModel):
    """Shared API model base aligned with shared JSON Schema additionalProperties=false."""

    model_config = ConfigDict(extra="forbid")
