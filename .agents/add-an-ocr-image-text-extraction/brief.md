Add OCR image-text extraction via multimodal LLM; image becomes a first-class working selection alongside text.

FILE: /home/sergiom/Code/ghostpen/src-tauri/src/pal/mod.rs
Define struct ClipboardImage { mime: String, bytes: Vec<u8> }. Add trait methods: read_image() -> Result<Option<ClipboardImage>>, write_image(&ClipboardImage) -> Result<()>.

FILE: /home/sergiom/Code/ghostpen/src-tauri/src/pal/clipboard.rs
ArboardClipboard::read_image: call arboard::get_image(), encode RGBA→PNG via `image` crate. ArboardClipboard::write_image: decode→RGBA, call set_image(). WaylandClipboard: replace String cache with enum ClipData{Text(String), Image(ClipboardImage)}. Both read_text/read_image check owned first (self-read deadlock prevention). write_image serves on MIME "image/png" with same generation+owned guard as text.

FILE: /home/sergiom/Code/ghostpen/src-tauri/Cargo.toml
Add: image={version="0.25",default-features=false,features=["png"]}, base64="0.22"

FILE: /home/sergiom/Code/ghostpen/src-tauri/src/image_util.rs (NEW)
fn resize_to_max_dimension(png: &[u8], max: u32)->Result<Vec<u8>>; fn png_dimensions(png: &[u8])->Result<(u32,u32)>; fn to_data_uri(png: &[u8])->String returns "data:image/png;base64,..."

FILE: /home/sergiom/Code/ghostpen/src-tauri/src/lib.rs
enum SelectionContent{Empty,Text(String),Image(ClipboardImage)}, NOT #[derive(Serialize)]. enum ClipboardSnapshot{Empty,Text(String),Image}. Add AppState: saved_clipboard: Mutex<ClipboardSnapshot>, current_input: Mutex<SelectionContent>. trigger_menu_flow: snapshot (read_text→if empty read_image→else Empty) to saved_clipboard before copy, reset current_input=Empty. #[tauri::command] extract_image_text: if current_input!=Image return error; resize image to settings.ocr.max_dimension; call ai::run_completion(UserContent::ImageWithText); store result in current_input=Text; return String. #[derive(Serialize)] #[serde(tag="kind")] SelectionInfo enum{Empty,Text{text:String},Image{preview:String,width:u32,height:u32}}. get_selection: read_text; if non-empty→current_input=Text, return SelectionInfo::Text; else read_image; if Some→current_input=Image, preview at 512px, return SelectionInfo::Image; else→current_input=Empty, return Empty. process_inner: read current_input (fallback to clipboard if Empty); if Image→error "Use Extract Text first". restore: call restore_original_clipboard(pal, snapshot) by kind.

FILE: /home/sergiom/Code/ghostpen/src-tauri/src/ai.rs
enum UserContent{Text(String),ImageWithText{text:String,data_uri:String}}. Change run_completion(profile,system,content:&UserContent). Serialize Text→content:"string"; ImageWithText→content:[{type:"text",text:...},{type:"image_url",image_url:{url:"data:image/png;base64,..."}}]. Add fn ocr_system_prompt()->&'static str. Update all text callers (process_inner, etc) to wrap with UserContent::Text(...).

FILE: /home/sergiom/Code/ghostpen/src-tauri/src/config.rs
struct OcrSettings{max_dimension:u32,system_prompt:String,model_override:String}, defaults to 1024/""/empty. Add #[serde(default)] ocr:OcrSettings to Settings.

FILE: /home/sergiom/Code/ghostpen/src/api.ts
type SelectionInfo = {kind:"empty"}|{kind:"text",text:string}|{kind:"image",preview:string,width:number,height:number}. export getSelection():Promise<SelectionInfo>, export extractImageText():Promise<string>. Add OcrSettings interface; add ocr to Settings type.

FILE: /home/sergiom/Code/ghostpen/src/Menu.tsx
selection: SelectionInfo (init {kind:"empty"}). If kind==="image": show preview <img>, Extract Text button→extractImageText()→update selection to {kind:"text",text:result}, actions disabled. If kind==="text": existing flow. Enter key triggers Extract Text when image active.

FILE: /home/sergiom/Code/ghostpen/src/Settings.tsx
Card "Image Text Extraction (OCR)": max dimension 512–2048 input (default 1024), system prompt textarea (empty=built-in), model override (empty=active profile). Note: "Extraction sends image to your active AI endpoint (may be cloud)."

VERIFY:
cargo check -p ghostpen --all-targets; cargo test --lib image_util; cargo test --lib ai::tests; npm run build; Manual: copy text→trigger→actions work (regression); Manual: copy image→preview+Extract shown, actions disabled; Manual: Extract→text→action→pasted, original image restored (synthetic mode).
