# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
import logging
import os
from typing import Any

import vertexai
from dotenv import load_dotenv
from google.adk.artifacts import GcsArtifactService, InMemoryArtifactService
from google.cloud import logging as google_cloud_logging
from vertexai.agent_engines.templates.adk import AdkApp

from app.agent import app as adk_app
from app.app_utils.telemetry import setup_telemetry
from app.app_utils.typing import Feedback

# Load environment variables from .env file at runtime
load_dotenv()


class AgentEngineApp(AdkApp):
    def project_id(self) -> str | None:
        """Return the project ID without calling Resource Manager.

        The base class resolves project number -> ID via a Resource Manager
        gRPC call, which Agent Gateway egress blocks (unregistered
        destination), crashing startup with a RetryError. We know our
        project ID, so short-circuit the lookup.
        """
        return (
            os.environ.get("GOOGLE_CLOUD_PROJECT")
            or os.environ.get("APP_GOOGLE_CLOUD_PROJECT")
            or self._tmpl_attrs.get("project")
        )

    def set_up(self) -> None:
        """Initialize the agent engine app with logging and telemetry."""
        # Pass the project explicitly: deriving it from the project number
        # requires a Resource Manager call, which the Agent Gateway egress
        # path blocks (unregistered destination). GOOGLE_CLOUD_PROJECT is
        # reserved on Agent Engine, so we use APP_GOOGLE_CLOUD_PROJECT.
        project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get(
            "APP_GOOGLE_CLOUD_PROJECT"
        )
        if project:
            vertexai.init(project=project)
        else:
            vertexai.init()
        setup_telemetry()
        super().set_up()
        logging.basicConfig(level=logging.INFO)
        if os.environ.get("INTEGRATION_TEST"):
            self._cloud_logger = None
        else:
            try:
                logging_client = google_cloud_logging.Client(
                    project=self.project_id()
                )
                self._cloud_logger = logging_client.logger(__name__)
            except Exception:
                # Fall back to stdout logging (captured by Agent Engine);
                # direct Cloud Logging writes may be blocked by the gateway.
                logging.exception("Cloud Logging client unavailable")
                self._cloud_logger = None
        if gemini_location:
            os.environ["GOOGLE_CLOUD_LOCATION"] = gemini_location

    def register_feedback(self, feedback: dict[str, Any]) -> None:
        """Collect and log feedback."""
        feedback_obj = Feedback.model_validate(feedback)
        if self._cloud_logger:
            self._cloud_logger.log_struct(
                feedback_obj.model_dump(), severity="INFO"
            )
        else:
            logging.info("Feedback: %s", feedback_obj.model_dump())

    def register_operations(self) -> dict[str, list[str]]:
        """Registers the operations of the Agent."""
        operations = super().register_operations()
        operations[""] = [*operations.get("", []), "register_feedback"]
        return operations


def _memory_service_builder():
    """Explicitly wire the real Memory Bank service on Agent Engine.

    The AdkApp default is supposed to do this when GOOGLE_CLOUD_AGENT_ENGINE_ID
    is set, but it silently fell back to InMemoryMemoryService in our runtime —
    memories were never written or recalled. Pin it explicitly.
    """
    import logging

    engine_id = os.environ.get("GOOGLE_CLOUD_AGENT_ENGINE_ID")
    if not engine_id:
        from google.adk.memory.in_memory_memory_service import InMemoryMemoryService

        logging.info("MemoryBank: no engine id in env; using InMemoryMemoryService")
        return InMemoryMemoryService()
    from google.adk.memory.vertex_ai_memory_bank_service import (
        VertexAiMemoryBankService,
    )

    project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get(
        "APP_GOOGLE_CLOUD_PROJECT"
    )
    location = os.environ.get("GOOGLE_CLOUD_AGENT_ENGINE_LOCATION") or os.environ.get(
        "GOOGLE_CLOUD_REGION", "us-east4"
    )
    logging.info(
        "MemoryBank: wiring VertexAiMemoryBankService project=%s location=%s engine=%s",
        project, location, engine_id,
    )
    return VertexAiMemoryBankService(
        project=project, location=location, agent_engine_id=engine_id
    )


gemini_location = os.environ.get("GOOGLE_CLOUD_LOCATION")
agent_engine = AgentEngineApp(
    app=adk_app,
    memory_service_builder=_memory_service_builder,
    artifact_service_builder=lambda: (
        GcsArtifactService(bucket_name=os.environ.get("LOGS_BUCKET_NAME"))
        if os.environ.get("LOGS_BUCKET_NAME")
        and not os.environ.get("INTEGRATION_TEST")
        else InMemoryArtifactService()
    ),
)
