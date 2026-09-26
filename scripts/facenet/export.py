"""Export the actual pretrained FaceNet weights and verify Core ML numerical parity.
Run with the pinned requirements on macOS. No enrollment photos are downloaded.
"""
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from facenet_pytorch import InceptionResnetV1
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'phone-app/ios/Copilot/FaceNet.mlpackage'
MODEL_ID = 'facenet-vggface2-512-vision-eyes-v1'

torch.manual_seed(7)
torch.set_num_threads(2)
weights = Path(torch.hub.get_dir()).parent / 'checkpoints/20180402-114759-vggface2.pt'
expected_sha = '281cebca8662831adb987a874bdcb36e73f5b1c6dc5ee5878f305e985625d99b'
if not weights.exists():
    weights.parent.mkdir(parents=True, exist_ok=True)
    torch.hub.download_url_to_file(
        'https://github.com/timesler/facenet-pytorch/releases/download/v2.2.9/20180402-114759-vggface2.pt',
        str(weights), hash_prefix=expected_sha)
if hashlib.sha256(weights.read_bytes()).hexdigest() != expected_sha:
    raise RuntimeError('Unexpected FaceNet checkpoint checksum; refusing to load it')
model = InceptionResnetV1(pretrained='vggface2').eval()
example = torch.zeros(1, 3, 160, 160)
traced = torch.jit.trace(model, example)
converted = ct.convert(
    traced,
    inputs=[ct.ImageType(name='face', shape=example.shape, scale=1 / 128,
                         bias=[-127.5 / 128] * 3, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name='embedding')],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
converted.author = 'Tim Esler; David Sandberg (pretrained FaceNet); Aside (Core ML export)'
converted.license = 'MIT (implementation); see ThirdParty/FaceNet-NOTICE.md for weights provenance'
converted.short_description = 'VGGFace2 InceptionResnetV1 FaceNet: RGB 160x160 to 512-dimensional identity embedding'
converted.user_defined_metadata['aside.model_id'] = MODEL_ID
converted.input_description['face'] = 'Upright eye-aligned RGB face; normalization (pixel - 127.5) / 128 is built in'
converted.output_description['embedding'] = 'L2-normalized 512-dimensional embedding'
# Numerical checks exercise real image preprocessing and the complete network.
errors = []
rng = np.random.default_rng(7)
for pixels in [np.zeros((160, 160, 3), dtype=np.uint8),
               np.full((160, 160, 3), 127, dtype=np.uint8),
               rng.integers(0, 256, (160, 160, 3), dtype=np.uint8)]:
    tensor = torch.from_numpy(pixels.copy()).permute(2, 0, 1).float().unsqueeze(0)
    with torch.no_grad():
        expected = model((tensor - 127.5) / 128).numpy().reshape(-1)
    actual = converted.predict({'face': Image.fromarray(pixels)})['embedding'].reshape(-1)
    error = float(np.linalg.norm(expected - actual))
    assert actual.size == 512 and np.isfinite(actual).all() and error < 0.02, error
    errors.append(error)
converted.save(str(OUTPUT))
manifest = {'model_id': MODEL_ID, 'source': 'https://github.com/timesler/facenet-pytorch',
            'weights_sha256': hashlib.sha256(weights.read_bytes()).hexdigest(),
            'coreml_parity_l2_errors': errors,
            'note': 'Synthetic parity checks verify conversion, not recognition accuracy.'}
(ROOT / 'scripts/facenet/model-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
print(f'Saved {OUTPUT}')
