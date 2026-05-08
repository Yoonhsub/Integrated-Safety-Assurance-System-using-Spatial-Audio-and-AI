from enum import Enum
from pydantic import Field, ConfigDict, model_validator

from app.schemas.base import StrictApiModel


NON_BLANK_PATTERN = r"\S"


class NotificationType(str, Enum):
    SAFETY_ALERT = "SAFETY_ALERT"
    RIDE_REQUEST = "RIDE_REQUEST"
    SYSTEM = "SYSTEM"


class NotificationRequest(StrictApiModel):
    model_config = ConfigDict(json_schema_extra={
        "oneOf": [
            {
                "required": ["targetUserId"],
                "properties": {
                    "targetUserId": {"type": "string", "minLength": 1, "pattern": "\\S"},
                    "targetDriverId": {"type": "null"}
                }
            },
            {
                "required": ["targetDriverId"],
                "properties": {
                    "targetUserId": {"type": "null"},
                    "targetDriverId": {"type": "string", "minLength": 1, "pattern": "\\S"}
                }
            }
        ]
    })
    targetUserId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    targetDriverId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    type: NotificationType
    title: str
    body: str
    data: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_target(self) -> "NotificationRequest":
        if (self.targetUserId is None) == (self.targetDriverId is None):
            raise ValueError("targetUserId와 targetDriverId 중 정확히 하나만 지정해야 합니다.")
        if self.targetUserId is not None and not self.targetUserId.strip():
            raise ValueError("targetUserId는 비어 있지 않은 문자열이어야 합니다.")
        if self.targetDriverId is not None and not self.targetDriverId.strip():
            raise ValueError("targetDriverId는 비어 있지 않은 문자열이어야 합니다.")
        return self


class NotificationResponse(StrictApiModel):
    accepted: bool
    messageId: str | None = None
    detail: str
