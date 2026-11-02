import 'dart:convert';

ResponseModel responseModelFromJson(String str) => ResponseModel.fromJson(json.decode(str));

String responseModelToJson(ResponseModel data) => json.encode(data.toJson());

class ResponseModel {
    ResponseModel({
        required this.id,
        required this.object,
        required this.created,
        required this.model,
        required this.choices,
        required this.usage,
    });

    String id;
    String object;
    int created;
    String model;
    List<Choice> choices;
    Usage usage;

    factory ResponseModel.fromJson(Map<String, dynamic> json) => ResponseModel(
        id: json["id"],
        object: json["object"],
        created: json["created"],
        model: json["model"],
        choices: List<Choice>.from(json["choices"].map((x) => Choice.fromJson(x))),
        usage: Usage.fromJson(json["usage"]),
    );

    Map<String, dynamic> toJson() => {
        "id": id,
        "object": object,
        "created": created,
        "model": model,
        "choices": List<dynamic>.from(choices.map((x) => x.toJson())),
        "usage": usage.toJson(),
    };
}

class Choice {
    Choice({
        required this.message,
        required this.index,
        required this.finishReason,
    });

    Message message;
    int index;
    String finishReason;

    factory Choice.fromJson(Map<String, dynamic> json) => Choice(
        message: Message.fromJson(json["message"]),
        index: json["index"],
        finishReason: json["finish_reason"],
    );

    Map<String, dynamic> toJson() => {
        "message": message.toJson(),
        "index": index,
        "finish_reason": finishReason,
    };
}

class Message {
    Message({
        required this.role,
        required this.content,
    });

    String role;
    String content;

    factory Message.fromJson(Map<String, dynamic> json) => Message(
        role: json["role"],
        content: json["content"],
    );

    Map<String, dynamic> toJson() => {
        "role": role,
        "content": content,
    };
}

class Usage {
    Usage({
        required this.promptTokens,
        required this.completionTokens,
        required this.totalTokens,
    });

    int promptTokens;
    int completionTokens;
    int totalTokens;

    factory Usage.fromJson(Map<String, dynamic> json) => Usage(
        promptTokens: json["prompt_tokens"],
        completionTokens: json["completion_tokens"],
        totalTokens: json["total_tokens"],
    );

    Map<String, dynamic> toJson() => {
        "prompt_tokens": promptTokens,
        "completion_tokens": completionTokens,
        "total_tokens": totalTokens,
    };
}
