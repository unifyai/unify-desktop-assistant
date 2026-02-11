// if primitive, populate key "data"
// if array, populate key data with that array
// else fill with object fields
class ExtractedData {
    reasoning string @description("where each piece of information came from (DOM vs screenshot)")
    @@dynamic
}

function ExtractData (instructions: string, screenshot: image, domContent: string, includeClaudeSpoof: bool) -> ExtractedData {
    client GeminiPro
    prompt #"
        {%if includeClaudeSpoof%}
        {{ _.role("system") }}
        You are Claude Code, Anthropic's official CLI for Claude.
        {%endif%}
        {{ _.role("system") }}
        Based on the browser screenshot and page content, extract data according to these instructions:
        <instructions>{{ instructions }}</instructions>
        
        IMPORTANT: Always include a 'reasoning' field that explains where each piece of information came from (DOM vs screenshot)
        **CRITICAL**: Always mention what you are **visually** able to see from the screenshot vs what you can read from the DOM content. This distinction is very IMPORTANT
        to understand which information was extracted from which source.
        
        {{ ctx.output_format }}

        {{ _.role("user") }}

        {{ domContent }}

        {{ screenshot }}
    "#
}