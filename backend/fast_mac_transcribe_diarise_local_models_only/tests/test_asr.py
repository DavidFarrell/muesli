from diarise_transcribe import asr


def test_ensure_loaded_shares_one_model_across_instances(monkeypatch) -> None:
    asr._model_cache.clear()

    load_calls: list[str] = []

    def fake_from_pretrained(model_id: str):
        load_calls.append(model_id)
        return object()

    monkeypatch.setattr(asr, "from_pretrained", fake_from_pretrained)

    first = asr.ASRModel("fake-model")
    second = asr.ASRModel("fake-model")

    first._ensure_loaded()
    second._ensure_loaded()

    assert load_calls == ["fake-model"]
    assert first._model is second._model


def test_ensure_loaded_loads_separately_per_model_id(monkeypatch) -> None:
    asr._model_cache.clear()

    load_calls: list[str] = []

    def fake_from_pretrained(model_id: str):
        load_calls.append(model_id)
        return object()

    monkeypatch.setattr(asr, "from_pretrained", fake_from_pretrained)

    first = asr.ASRModel("model-a")
    second = asr.ASRModel("model-b")

    first._ensure_loaded()
    second._ensure_loaded()

    assert load_calls == ["model-a", "model-b"]
    assert first._model is not second._model
