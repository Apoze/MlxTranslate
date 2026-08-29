"""Deterministic local fixes for the pinned mlx-audio Voxtral runtime."""

import codecs
from importlib.util import find_spec
from pathlib import Path
import warnings


def replace_exact(
    path: Path,
    old: str,
    new: str,
    *,
    compatible_marker: str | None = None,
) -> None:
    source = path.read_text(encoding="utf-8")
    if new in source or (compatible_marker and compatible_marker in source):
        return
    if old not in source:
        raise RuntimeError(f"audited patch context not found in {path}")
    path.write_text(source.replace(old, new, 1), encoding="utf-8")


spec = find_spec("mlx_audio")
if spec is None or not spec.submodule_search_locations:
    raise RuntimeError("mlx_audio is not installed in the managed environment")

root = Path(next(iter(spec.submodule_search_locations)))
voxtral = root / "stt" / "models" / "voxtral_realtime"
streaming = voxtral / "streaming.py"

replace_exact(
    voxtral / "tokenizer.py",
    "import base64\nimport json\n",
    "import base64\nimport codecs\nimport json\n",
)
replace_exact(
    voxtral / "tokenizer.py",
    """    def decode(self, token_ids) -> str:
        \"\"\"Decode a sequence of token IDs to text.\"\"\"
        out = bytearray()
        for token_id in token_ids:
            tid = int(token_id)
            if tid < self.n_special or tid in self.special_ids:
                continue
            out += self.token_bytes(tid)
        return out.decode(\"utf-8\", errors=\"replace\")
""",
    """    def decode(self, token_ids, *, final: bool = False) -> str:
        \"\"\"Decode complete UTF-8 scalars without corrupting split tokens.\"\"\"
        out = bytearray()
        for token_id in token_ids:
            tid = int(token_id)
            if tid < self.n_special or tid in self.special_ids:
                continue
            out += self.token_bytes(tid)
        decoder = codecs.getincrementaldecoder(\"utf-8\")(errors=\"strict\")
        return decoder.decode(bytes(out), final=final)
""",
)
if "    def final_text(self) -> str:\n" not in streaming.read_text(encoding="utf-8"):
    replace_exact(
        streaming,
        """    @property
    def done(self) -> bool:
        return self._done

    def feed(self, samples: np.ndarray) -> None:
""",
        """    @property
    def done(self) -> bool:
        return self._done

    @property
    def final_text(self) -> str:
        if not self._done:
            raise RuntimeError(\"Voxtral final text requested before the stream ended\")
        eos = self.model.config.eos_token_id
        return self.model._tokenizer.decode(
            [token for token in self.generated if token != eos], final=True
        )

    def feed(self, samples: np.ndarray) -> None:
""",
    )
replace_exact(
    root / "server.py",
    """    async def send_done():
        text = \"\".join(full_text_parts)
""",
    """    async def send_done():
        text = session.final_text
""",
)
replace_exact(
    root / "server.py",
    """        for delta in deltas:
            full_text_parts.append(delta)
            await send_event(
                {
                    "type": "conversation.item.input_audio_transcription.delta",
                    "item_id": current_item_id,
                    "content_index": 0,
                    "delta": delta,
                }
            )
        return session.done
""",
    """        for delta in deltas:
            full_text_parts.append(delta)
            await send_event(
                {
                    "type": "conversation.item.input_audio_transcription.delta",
                    "item_id": current_item_id,
                    "content_index": 0,
                    "delta": delta,
                }
            )
        drain_markers = getattr(session, "drain_emission_markers", None)
        if drain_markers is not None:
            for marker in drain_markers():
                await send_event(
                    {
                        "type": "whisperasr.voxtral.emission_marker",
                        **marker,
                    }
                )
        return session.done
""",
)

replace_exact(
    streaming,
    "import math\nimport queue\n",
    "import codecs\nimport math\nimport queue\n",
)
replace_exact(
    streaming,
    "import codecs\nimport math\nimport queue\n",
    "import codecs\nimport math\nimport queue\nimport warnings\n",
)
replace_exact(
    streaming,
    """        self._next_k = max_k_inclusive + 1
        frames_mx = mx.array(frames_np, dtype=mx.float32) * self._window[None, :]
        spectrum = mx.fft.rfft(frames_mx, n=self.window_size, axis=-1)
        magnitudes = mx.abs(spectrum) ** 2  # [n_new, freq_bins]
        # Drop-last (the batch path's magnitudes[:-1, :] over the TIME axis)
        # is applied globally via max_k_inclusive when final=True, not here.
        mel_spec = magnitudes @ self.mel_filters  # [n_new, mel_bins]
        log_spec = mx.log10(mx.maximum(mel_spec, 1e-10))
        min_val = self.global_log_mel_max - 8.0
        log_spec = mx.maximum(log_spec, min_val)
        log_spec = (log_spec + 4.0) / 4.0
        out = log_spec.T  # [mel_bins, n_new]
        mx.eval(out)
        return out
""",
    """        self._next_k = max_k_inclusive + 1
        frames_mx = mx.array(frames_np, dtype=mx.float32) * self._window[None, :]
        spectrum = mx.fft.rfft(frames_mx, n=self.window_size, axis=-1)
        magnitudes = mx.abs(spectrum) ** 2  # [n_new, freq_bins]
        # Drop-last (the batch path's magnitudes[:-1, :] over the TIME axis)
        # is applied globally via max_k_inclusive when final=True, not here.
        mel_spec = magnitudes @ self.mel_filters  # [n_new, mel_bins]
        log_spec = mx.log10(mx.maximum(mel_spec, 1e-10))
        min_val = self.global_log_mel_max - 8.0
        log_spec = mx.maximum(log_spec, min_val)
        log_spec = (log_spec + 4.0) / 4.0
        out = log_spec.T  # [mel_bins, n_new]
        mx.eval(out)

        # No future frame can reference samples before this index. Keeping only
        # the unresolved window makes the long-lived frontend constant-memory.
        self.trim(max(0, self._next_k * self.hop_length - self.pad_size))
        return out
""",
)
replace_exact(
    streaming,
    """        # Save the last (kernel - stride) inputs as state. After this call the
        # next kernel window will start exactly at position `n_out * stride`
        # within the current context, leaving `context.shape[0] - n_out*stride`
        # samples as "leftover", which must be (kernel - stride) by construction
        # when the input stream has been packed with no gaps.
        if self._keep > 0:
            # Guard: if leftover < keep (early edge), save all.
            leftover = context.shape[0] - n_out * self.stride
            if leftover <= 0:
                self._state = None
            elif leftover >= self._keep:
                self._state = context[-self._keep :]
            else:
                self._state = context[-leftover:]
        else:
            self._state = None
""",
    """        # Retain the exact unconsumed suffix. For strided convolutions it
        # can be larger than (kernel - stride) when a chunk ends off phase.
        leftover = context.shape[0] - n_out * self.stride
        self._state = context[-leftover:] if leftover > 0 else None
""",
)
replace_exact(
    streaming,
    """        max_tokens: int = 4096,
        temperature: float = 0.0,
""",
    """        max_tokens: Optional[int] = None,
        temperature: float = 0.0,
""",
)
replace_exact(
    voxtral / "voxtral_realtime.py",
    """    def create_streaming_session(
        self,
        *,
        max_tokens: int = 4096,
        temperature: float = 0.0,
""",
    """    def create_streaming_session(
        self,
        *,
        max_tokens: Optional[int] = None,
        temperature: float = 0.0,
""",
)
replace_exact(
    streaming,
    """        self._adapter_frames: list[mx.array] = []
        self._prefilled = False
        self._cache = None
        self._next_tok: Optional[mx.array] = None
        self._pos = self._prompt_len
        self.generated: list[int] = []
        self._prev_text = ""
        self._trailing_after_close = 0
""",
    """        self._adapter_frames: list[mx.array] = []
        self._adapter_start = 0
        self._prefilled = False
        self._cache = None
        self._next_tok: Optional[mx.array] = None
        self._next_tok_emitted = False
        self._pos = self._prompt_len
        self.generated: list[int] = []
        self._text_decoder = codecs.getincrementaldecoder("utf-8")(errors="strict")
        self._text_parts: list[str] = []
        self._text_finalized = False
        self._trailing_after_close = 0
""",
    compatible_marker="        self._emission_markers: list[dict[str, int | bool]] = []\n",
)
replace_exact(
    streaming,
    """        self._text_decoder = codecs.getincrementaldecoder("utf-8")(errors="strict")
        self._text_parts: list[str] = []
        self._text_finalized = False
        self._trailing_after_close = 0
""",
    """        self._text_decoder = codecs.getincrementaldecoder("utf-8")(errors="strict")
        self._text_parts: list[str] = []
        self._text_utf8_count = 0
        self._text_finalized = False
        self._streaming_word_token_id = 33
        if self._streaming_word_token_id not in model._tokenizer.special_ids:
            raise RuntimeError("Voxtral tokenizer is missing [STREAMING_WORD] token 33")
        self._emission_markers: list[dict[str, int | bool]] = []
        self._trailing_after_close = 0
""",
    compatible_marker="        self._text_utf8_count = 0\n",
)
replace_exact(
    streaming,
    """        self._text_utf8_count = 0
        self._text_finalized = False
        self._streaming_word_token_id = 33
""",
    """        self._text_utf8_count = 0
        self._text_finalized = False
        self._incomplete_utf8_tail = b""
        self._streaming_word_token_id = 33
""",
)
replace_exact(
    streaming,
    """    @property
    def final_text(self) -> str:
        if not self._done:
            raise RuntimeError("Voxtral final text requested before the stream ended")
        eos = self.model.config.eos_token_id
        return self.model._tokenizer.decode(
            [token for token in self.generated if token != eos], final=True
        )

    def feed(self, samples: np.ndarray) -> None:
""",
    """    @property
    def final_text(self) -> str:
        if not self._done:
            raise RuntimeError("Voxtral final text requested before the stream ended")
        if not self._text_finalized:
            tail = self._text_decoder.decode(b"", final=True)
            if tail:
                self._text_parts.append(tail)
            self._text_finalized = True
        return "".join(self._text_parts)

    def _record_token(self, token: int) -> str:
        self.generated.append(token)
        if token == self.model.config.eos_token_id:
            return ""
        delta = self._text_decoder.decode(
            self.model._tokenizer.token_bytes(token), final=False
        )
        if delta:
            self._text_parts.append(delta)
        return delta

    def feed(self, samples: np.ndarray) -> None:
""",
    compatible_marker="    def drain_emission_markers(self) -> list[dict[str, int | bool]]:\n",
)
replace_exact(
    streaming,
    """    @property
    def final_text(self) -> str:
        if not self._done:
            raise RuntimeError("Voxtral final text requested before the stream ended")
        if not self._text_finalized:
            tail = self._text_decoder.decode(b"", final=True)
            if tail:
                self._text_parts.append(tail)
            self._text_finalized = True
        return "".join(self._text_parts)
""",
    """    @property
    def final_text(self) -> str:
        if not self._done:
            raise RuntimeError("Voxtral final text requested before the stream ended")
        if not self._text_finalized:
            pending, _ = self._text_decoder.getstate()
            if pending:
                # The fixed audio horizon can end between Tekken byte tokens.
                # Those bytes were never emitted as text: retain the exact valid
                # delta prefix and report the rejected fragment instead of
                # corrupting it with U+FFFD or failing the complete utterance.
                self._incomplete_utf8_tail = bytes(pending)
                warnings.warn(
                    "Voxtral rejected an incomplete terminal UTF-8 fragment "
                    f"({self._incomplete_utf8_tail.hex()})",
                    RuntimeWarning,
                    stacklevel=2,
                )
                self._text_decoder.reset()
            else:
                tail = self._text_decoder.decode(b"", final=True)
                if tail:
                    self._text_parts.append(tail)
            self._text_finalized = True
        return "".join(self._text_parts)
""",
)
replace_exact(
    streaming,
    """    def _record_token(self, token: int) -> str:
        self.generated.append(token)
        if token == self.model.config.eos_token_id:
            return ""
        delta = self._text_decoder.decode(
            self.model._tokenizer.token_bytes(token), final=False
        )
        if delta:
            self._text_parts.append(delta)
        return delta

    def feed(self, samples: np.ndarray) -> None:
""",
    """    def _record_token(self, token: int) -> str:
        generated_index = len(self.generated)
        decoder_position = self._pos
        self.generated.append(token)
        if token == self._streaming_word_token_id:
            proxy_frame = generated_index - self._n_delay
            self._emission_markers.append(
                {
                    "generated_index": generated_index,
                    "decoder_position": decoder_position,
                    "delay_frames": self._n_delay,
                    "proxy_end_sample": max(0, proxy_frame) * self._raw_tok,
                    "group_text_start_utf8": self._text_utf8_count,
                    "is_usable": (
                        generated_index == decoder_position - self._prompt_len
                        and not self._text_decoder.getstate()[0]
                        and proxy_frame >= 0
                    ),
                }
            )
            return ""
        if token == self.model.config.eos_token_id:
            return ""
        delta = self._text_decoder.decode(
            self.model._tokenizer.token_bytes(token), final=False
        )
        if delta:
            self._text_parts.append(delta)
            self._text_utf8_count += len(delta.encode("utf-8"))
        return delta

    def drain_emission_markers(self) -> list[dict[str, int | bool]]:
        markers, self._emission_markers = self._emission_markers, []
        return markers

    def feed(self, samples: np.ndarray) -> None:
""",
)
replace_exact(
    streaming,
    """    def _n_adapter(self) -> int:
        return sum(a.shape[0] for a in self._adapter_frames)

    def _coalesce_adapter(self) -> mx.array:
        if len(self._adapter_frames) > 1:
            merged = mx.concatenate(self._adapter_frames, axis=0)
            mx.eval(merged)
            self._adapter_frames = [merged]
        return self._adapter_frames[0]

    def _adapter_at(self, pos: int) -> mx.array:
        if len(self._adapter_frames) > 8:
            self._coalesce_adapter()
        offset = 0
        for piece in self._adapter_frames:
            if pos < offset + piece.shape[0]:
                return piece[pos - offset]
            offset += piece.shape[0]
        raise IndexError(f"pos={pos} out of adapter range (have {offset})")
""",
    """    def _n_adapter(self) -> int:
        return self._adapter_start + sum(a.shape[0] for a in self._adapter_frames)

    def _coalesce_adapter(self) -> mx.array:
        if len(self._adapter_frames) > 1:
            merged = mx.concatenate(self._adapter_frames, axis=0)
            mx.eval(merged)
            self._adapter_frames = [merged]
        return self._adapter_frames[0]

    def _trim_adapter(self, keep_from: int) -> None:
        while self._adapter_frames:
            piece_len = self._adapter_frames[0].shape[0]
            piece_end = self._adapter_start + piece_len
            if keep_from < piece_end:
                break
            self._adapter_frames.pop(0)
            self._adapter_start = piece_end
        if self._adapter_frames and keep_from > self._adapter_start:
            drop = keep_from - self._adapter_start
            remaining = mx.contiguous(self._adapter_frames[0][drop:])
            mx.eval(remaining)
            self._adapter_frames[0] = remaining
            self._adapter_start = keep_from

    def _adapter_at(self, pos: int) -> mx.array:
        if len(self._adapter_frames) > 8:
            self._coalesce_adapter()
        offset = self._adapter_start
        for piece in self._adapter_frames:
            if pos < offset + piece.shape[0]:
                return piece[pos - offset]
            offset += piece.shape[0]
        raise IndexError(f"pos={pos} out of adapter range (have {offset})")
""",
)
replace_exact(
    streaming,
    """        self._next_tok = self.model._next_token_mx(logits, self.temperature)
        mx.async_eval(self._next_tok)

    def _decode_some(self, max_decode_tokens: int) -> list[str]:
""",
    """        self._next_tok = self.model._next_token_mx(logits, self.temperature)
        mx.async_eval(self._next_tok)
        self._trim_adapter(self._pos)

    def _decode_some(self, max_decode_tokens: int) -> list[str]:
""",
)
replace_exact(
    streaming,
    """    def _decode_some(self, max_decode_tokens: int) -> list[str]:
        deltas: list[str] = []
        eos = self.model.config.eos_token_id
        tok_emb = self.model.decoder.tok_embeddings

        for _ in range(max_decode_tokens):
            # Before consuming the pending token, make sure we'll be able
            # to run a forward pass for it (which needs adapter[pos] while
            # audio is still flowing). If neither adapter nor close is
            # ready, return and let the caller feed more audio.
            if self._n_adapter() <= self._pos and not self._flushed_close:
                return deltas

            if self._n_adapter() <= self._pos:
                # Closed and out of audio: the right-pad (silence) tokens we
                # appended at close() should already have let the model emit
                # EOS. Flush the last pending token without further padding —
                # matches voxmlx's finalize() behavior.
                token = int(self._next_tok.item())
                self.generated.append(token)
                text_so_far = self.model._tokenizer.decode(
                    [t for t in self.generated if t != eos]
                )
                if text_so_far != self._prev_text:
                    deltas.append(text_so_far[len(self._prev_text) :])
                    self._prev_text = text_so_far
                self._done = True
                return deltas

            # Dispatch the current forward BEFORE the .item() sync so the
            # previous step's eval overlaps with the current step's compute
            # queueing — this is the pipelining pattern voxmlx uses. We pass
            # ``self._next_tok`` (an mx.array living on the GPU) directly to
            # the embedding lookup instead of round-tripping via
            # ``mx.array([int(token)])``, which would force a CPU→GPU sync
            # on every step.
            prev_tok_mx = self._next_tok  # shape [], argmax result
            token_embed = tok_emb(prev_tok_mx.reshape(1))[0]
            embed = self._adapter_at(self._pos) + token_embed

            h, self._cache = self.model.decoder.forward(
                embed[None, :], start_pos=self._pos, cache=self._cache
            )
            logits = self.model.decoder.logits(h.squeeze(0))
            new_next_tok = self.model._next_token_mx(logits, self.temperature)
            mx.async_eval(new_next_tok)

            # Now read the PREVIOUS step's token from the GPU. This .item()
            # only waits for the argmax from the prior iteration — the
            # current iteration's forward is already queued.
            token = int(prev_tok_mx.item())
            self.generated.append(token)

            text_so_far = self.model._tokenizer.decode(
                [t for t in self.generated if t != eos]
            )
            if text_so_far != self._prev_text:
                deltas.append(text_so_far[len(self._prev_text) :])
                self._prev_text = text_so_far

            if token == eos or len(self.generated) > self.max_tokens:
                self._done = True
                return deltas

            self._next_tok = new_next_tok
            self._pos += 1
            if len(self.generated) % 256 == 0:
                mx.clear_cache()

        return deltas
""",
    """    def _decode_some(self, max_decode_tokens: int) -> list[str]:
        deltas: list[str] = []
        eos = self.model.config.eos_token_id
        tok_emb = self.model.decoder.tok_embeddings
        emitted = 0

        while emitted < max_decode_tokens:
            # The pending prediction is already final for this audio position;
            # publishing it does not require the next adapter frame. A real-model
            # parity test verifies identical token and delta sequences.
            if not self._next_tok_emitted:
                token = int(self._next_tok.item())
                delta = self._record_token(token)
                if delta:
                    deltas.append(delta)
                self._next_tok_emitted = True
                emitted += 1
                if token == eos:
                    self._done = True
                    return deltas
                if self.max_tokens is not None and len(self.generated) > self.max_tokens:
                    raise RuntimeError("Voxtral streaming token limit reached before EOS")

            if self._n_adapter() <= self._pos:
                if self._flushed_close:
                    self._done = True
                return deltas

            prev_tok_mx = self._next_tok
            token_embed = tok_emb(prev_tok_mx.reshape(1))[0]
            embed = self._adapter_at(self._pos) + token_embed
            h, self._cache = self.model.decoder.forward(
                embed[None, :], start_pos=self._pos, cache=self._cache
            )
            logits = self.model.decoder.logits(h.squeeze(0))
            new_next_tok = self.model._next_token_mx(logits, self.temperature)
            mx.async_eval(new_next_tok)

            self._next_tok = new_next_tok
            self._next_tok_emitted = False
            self._pos += 1
            self._trim_adapter(self._pos)
            if len(self.generated) % 256 == 0:
                mx.clear_cache()

        return deltas
""",
)

# A Japanese scalar split across three Tekken tokens must be buffered, never
# replaced or discarded. This runs on every freshly installed environment.
from mlx_audio.stt.models.voxtral_realtime.tokenizer import TekkenTokenizer
from mlx_audio.stt.models.voxtral_realtime.encoder import CausalConv1d
from mlx_audio.stt.models.voxtral_realtime.audio import compute_mel_filters
from mlx_audio.stt.models.voxtral_realtime.streaming import (
    StreamingCausalConv1d,
    StreamingMel,
    VoxtralStreamingSession,
)
from mlx_audio.stt.models.voxtral_realtime.voxtral_realtime import Model as VoxtralRealtimeModel
import inspect
import mlx.core as mx
import numpy as np

probe = TekkenTokenizer.__new__(TekkenTokenizer)
probe.n_special = 1000
probe.special_ids = {32, 33}
probe._bytes_cache = {}
pieces = {1000: b"\xe6", 1001: b"\x97", 1002: b"\xa5"}
probe.token_bytes = lambda token_id: pieces[token_id]
assert probe.decode([1000]) == ""
assert probe.decode([1000, 1001]) == ""
assert probe.decode([1000, 1001, 1002]) == "日"
assert probe.decode([1000, 1001, 1002], final=True) == "日"
try:
    probe.decode([1000], final=True)
except UnicodeDecodeError:
    pass
else:
    raise AssertionError("an incomplete final UTF-8 sequence was accepted")

# The production k=3/s=2 boundary must keep two frames when the first chunk is
# odd. The upstream aligned-chunk test does not exercise this phase.
mx.random.seed(0)
conv = CausalConv1d(4, 6, 3, stride=2)
x = mx.array(np.random.default_rng(0).standard_normal((360, 4)).astype(np.float32))
batch = conv(x[None, :, :]).squeeze(0)
stream_conv = StreamingCausalConv1d(conv)
streamed = mx.concatenate([stream_conv.step(x[:255]), stream_conv.step(x[255:])])
mx.eval(batch, streamed)
assert batch.shape == streamed.shape
assert float(mx.max(mx.abs(batch - streamed)).item()) < 1e-5

mel = StreamingMel(mx.array(compute_mel_filters(), dtype=mx.float32))
for _ in range(8):
    mel.append(np.zeros(2_560, dtype=np.float32))
    assert len(mel._buf) <= mel.window_size + mel.hop_length

adapter_probe = VoxtralStreamingSession.__new__(VoxtralStreamingSession)
adapter_probe._adapter_start = 0
adapter_probe._adapter_frames = [mx.arange(12).reshape(3, 4), mx.arange(8).reshape(2, 4)]
assert adapter_probe._n_adapter() == 5
adapter_probe._trim_adapter(3)
assert adapter_probe._adapter_start == 3
assert adapter_probe._n_adapter() == 5
assert int(adapter_probe._adapter_at(3)[0].item()) == 0
adapter_probe._trim_adapter(5)
assert adapter_probe._adapter_start == 5
assert adapter_probe._adapter_frames == []

# A helper session is continuous by default; an explicit caller cap remains an
# error instead of silently accepting audio after transcription has stopped.
assert inspect.signature(VoxtralStreamingSession).parameters["max_tokens"].default is None
assert (
    inspect.signature(VoxtralRealtimeModel.create_streaming_session)
    .parameters["max_tokens"]
    .default
    is None
)

# Exercise the actual incremental UTF-8 path used by the session.
class _ProbeConfig:
    eos_token_id = 2


class _ProbeModel:
    config = _ProbeConfig()
    _tokenizer = probe


session_probe = VoxtralStreamingSession.__new__(VoxtralStreamingSession)
session_probe.model = _ProbeModel()
session_probe.generated = [32] * 12
session_probe._prompt_len = 45
session_probe._pos = 45
session_probe._n_delay = 12
session_probe._raw_tok = 1_280
session_probe._text_decoder = codecs.getincrementaldecoder("utf-8")(errors="strict")
session_probe._text_parts = []
session_probe._text_utf8_count = 0
session_probe._streaming_word_token_id = 33
session_probe._emission_markers = []
assert session_probe._record_token(1000) == ""
assert session_probe._record_token(1001) == ""
assert session_probe._record_token(1002) == "日"
session_probe._pos = session_probe._prompt_len + len(session_probe.generated)
assert session_probe._record_token(33) == ""
assert session_probe.drain_emission_markers() == [
    {
        "generated_index": 15,
        "decoder_position": 60,
        "delay_frames": 12,
        "proxy_end_sample": 3_840,
        "group_text_start_utf8": 3,
        "is_usable": True,
    }
]
assert session_probe.drain_emission_markers() == []
session_probe._pos = 999
assert session_probe._record_token(33) == ""
assert session_probe.drain_emission_markers()[0]["is_usable"] is False
session_probe._pos = session_probe._prompt_len + len(session_probe.generated)
assert session_probe._record_token(1000) == ""
session_probe._pos = session_probe._prompt_len + len(session_probe.generated)
assert session_probe._record_token(33) == ""
assert session_probe.drain_emission_markers()[0]["is_usable"] is False

# A fixed decode horizon can end between byte-fallback tokens. Those bytes
# never became a text delta: preserve the exact valid prefix, expose the
# rejected terminal fragment, and keep rejecting genuinely invalid UTF-8.
terminal_probe = VoxtralStreamingSession.__new__(VoxtralStreamingSession)
terminal_probe.model = _ProbeModel()
terminal_probe.generated = []
terminal_probe._text_decoder = codecs.getincrementaldecoder("utf-8")(errors="strict")
terminal_probe._text_parts = ["日"]
terminal_probe._text_finalized = False
terminal_probe._incomplete_utf8_tail = b""
terminal_probe._done = True
assert terminal_probe._text_decoder.decode(b"\xe9\xad", final=False) == ""
with warnings.catch_warnings(record=True) as recorded:
    warnings.simplefilter("always")
    assert terminal_probe.final_text == "日"
assert terminal_probe._incomplete_utf8_tail == b"\xe9\xad"
assert len(recorded) == 1
assert "e9ad" in str(recorded[0].message)
try:
    codecs.getincrementaldecoder("utf-8")(errors="strict").decode(
        b"\xe9\xff", final=False
    )
except UnicodeDecodeError:
    pass
else:
    raise AssertionError("an invalid UTF-8 sequence was accepted")
