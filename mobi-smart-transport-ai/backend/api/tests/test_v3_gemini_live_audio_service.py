from app.services.v3_gemini_live_audio_service import (
    live_audio_setup_message,
    live_audio_text_message,
)


def test_live_audio_setup_uses_native_audio_model_and_existing_voice() -> None:
    setup = live_audio_setup_message(
        model="gemini-2.5-flash-native-audio-preview-12-2025",
        voice="Kore",
    )

    assert setup == {
        "setup": {
            "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {
                    "voiceConfig": {
                        "prebuiltVoiceConfig": {
                            "voiceName": "Kore",
                        }
                    }
                },
            },
            "systemInstruction": {
                "parts": [
                    {
                        "text": (
                            "You are MOBI's Korean transit-guidance voice for a blind passenger. "
                            "Speak the given Korean transcript like a warm, friendly real person speaking "
                            "right next to the listener — lively and genuinely human, with natural "
                            "conversational intonation, natural rhythm, and brief natural pauses. Never flat, "
                            "monotone, or robotic; let it sound expressive and caring. The transcript is "
                            "polite Korean (존댓말); keep that warm, respectful, polite tone. "
                            "Keep it clear and easy to understand. "
                            "Do not add, remove, paraphrase, translate, or answer anything — speak ONLY the provided transcript."
                        )
                    }
                ]
            },
        }
    }


def test_live_audio_text_message_keeps_transcript_explicit() -> None:
    assert live_audio_text_message(text="  사창사거리로 안내할게.  ") == {
        "realtimeInput": {
            "text": "Speak only this transcript:\n사창사거리로 안내할게.",
        }
    }
