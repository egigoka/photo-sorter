"""Convert a CLIP-style image encoder to Core ML and embed the category prompts.

Usage: clip_convert.py <siglip|pe> <labels.json> <out dir> <test image dir>

<labels.json> gives the prompts: any Resources/labels_*.json works, the embeddings in it are ignored.
Compile the result with: xcrun coremlcompiler compile <out dir>/<name>_image.mlpackage Models
"""
import sys, json, glob, numpy as np, torch, open_clip, coremltools as ct
from PIL import Image

# Key: OpenCLIP model, pretrained tag, name of the Core ML model, name of the labels file.
MODELS = {
    "siglip": ("ViT-B-16-SigLIP2", "webli", "siglip2_b16", "labels_siglip"),
    "pe": ("hf-hub:timm/PE-Core-B-16", None, "pe_core_b16", "labels_pe"),
}

key, labels_in, out_dir, test_dir = sys.argv[1:5]
NAME, pretrained, model_name, labels_name = MODELS[key]
model, _, preprocess = open_clip.create_model_and_transforms(NAME, pretrained=pretrained)
model.eval()
print(preprocess)
# The Core ML input below maps pixels to -1...1 at 224 x 224. The model must expect the same.
normalize = next(t for t in preprocess.transforms if hasattr(t, "mean"))
assert tuple(normalize.mean) == (0.5, 0.5, 0.5) and tuple(normalize.std) == (0.5, 0.5, 0.5), normalize
tokenizer = open_clip.get_tokenizer(NAME)

prompts = [(p["category"], p["prompt"]) for p in json.load(open(labels_in))["prompts"]]
with torch.no_grad():
    text = torch.nn.functional.normalize(model.encode_text(tokenizer([p for _, p in prompts])), dim=-1).numpy()
scale = float(model.logit_scale.exp())
json.dump({"model": model_name, "scale": scale, "prompts": [
    {"category": c, "prompt": p, "embedding": [round(float(x), 6) for x in e]} for (c, p), e in zip(prompts, text)
]}, open(f"{out_dir}/{labels_name}.json", "w"))
print("scale", scale, "dim", text.shape)

class ImageEncoder(torch.nn.Module):
    def __init__(self, clip):
        super().__init__()
        self.clip = clip
    def forward(self, x):
        return torch.nn.functional.normalize(self.clip.encode_image(x), dim=-1)

example = torch.rand(1, 3, 224, 224)
traced = torch.jit.trace(ImageEncoder(model), example)
ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 127.5, bias=[-1, -1, -1], color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
ml.save(f"{out_dir}/{model_name}_image.mlpackage")

cats = [c for c, _ in prompts]
def report(tag, e):
    l = scale * text @ e; p = np.exp(l - l.max()); p /= p.sum()
    agg = {}
    for c, v in zip(cats, p): agg[c] = agg.get(c, 0) + float(v)
    return tag + " " + str({k: round(v, 2) for k, v in sorted(agg.items(), key=lambda x: -x[1])[:3]})
for f in sorted(glob.glob(test_dir + "/*")):
    img = Image.open(f).convert("RGB").resize((224, 224), Image.BICUBIC)
    x = torch.from_numpy(np.asarray(img)).permute(2, 0, 1)[None].float() / 127.5 - 1
    with torch.no_grad(): et = traced(x).numpy().reshape(-1)
    ec = ml.predict({"image": img})["embedding"].reshape(-1); ec = ec / np.linalg.norm(ec)
    print(f.split("/")[-1], report("torch", et), report("coreml", ec), "cos", round(float(et @ ec), 4))
