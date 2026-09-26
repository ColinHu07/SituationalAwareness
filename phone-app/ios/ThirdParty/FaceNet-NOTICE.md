# FaceNet model provenance

The bundled `Copilot/FaceNet.mlpackage` is a float16 Core ML conversion of
`facenet-pytorch==2.6.0`'s InceptionResnetV1, pretrained on VGGFace2. It produces
512-dimensional unit embeddings. It is not an Apple Face ID model.

- Implementation: https://github.com/timesler/facenet-pytorch
- Original TensorFlow implementation: https://github.com/davidsandberg/facenet
- Weights: https://github.com/timesler/facenet-pytorch/releases/download/v2.2.9/20180402-114759-vggface2.pt
- Paper: https://arxiv.org/abs/1503.03832
- Implementation license: `FaceNet-MIT-LICENSE.txt`, copied from the installed 2.6.0 distribution.
- Checkpoint checksum and conversion parity: `scripts/facenet/model-manifest.json`.

The implementation's MIT license does not itself establish rights in the
VGGFace2 training images. Review the upstream pretrained-weight and dataset
terms for the intended distribution. No training images are included here.

Reproduction and app-specific validation are documented in `docs/FACENET.md`.
