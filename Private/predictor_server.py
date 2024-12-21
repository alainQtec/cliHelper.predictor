from fastapi import FastAPI, WebSocket
from transformers import AutoTokenizer, AutoModelForCausalLM
import sqlite3
import json
import asyncio
from typing import List, Dict
import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from collections import defaultdict

app = FastAPI()

class CommandPredictor:
    def __init__(self):
        # Initialize the model and tokenizer
        self.tokenizer = AutoTokenizer.from_pretrained("microsoft/CodeGPT-small-py")
        self.model = AutoModelForCausalLM.from_pretrained("microsoft/CodeGPT-small-py")
        self.vectorizer = TfidfVectorizer(ngram_range=(1, 3))
        self.command_patterns = defaultdict(int)
        self.init_database()

    def init_database(self):
        with sqlite3.connect("commands.db") as conn:
            c = conn.cursor()
            c.execute('''CREATE TABLE IF NOT EXISTS command_history
                        (command TEXT, context TEXT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP)''')
            conn.commit()

    async def predict_next_command(self, current_input: str, history: List[str]) -> List[Dict[str, float]]:
        # Combine ML approaches for better prediction

        # 1. Use transformer model for context-aware prediction
        inputs = self.tokenizer(current_input, return_tensors="pt")
        outputs = self.model.generate(
            inputs["input_ids"],
            max_length=50,
            num_return_sequences=3,
            temperature=0.7,
            pad_token_id=self.tokenizer.eos_token_id
        )

        ml_predictions = []
        for output in outputs:
            decoded = self.tokenizer.decode(output, skip_special_tokens=True)
            if decoded.startswith(current_input):
                ml_predictions.append(decoded)

        # 2. Use TF-IDF for frequency-based predictions
        if history:
            self.vectorizer.fit(history)
            similarities = self.vectorizer.transform([current_input])
            history_matrix = self.vectorizer.transform(history)
            scores = (similarities * history_matrix.T).A[0]

            # Combine both approaches
            combined_predictions = []
            seen = set()

            for pred in ml_predictions:
                if pred not in seen:
                    combined_predictions.append({"command": pred, "score": 0.8})
                    seen.add(pred)

            for idx in np.argsort(scores)[-3:]:
                if history[idx] not in seen:
                    combined_predictions.append({"command": history[idx], "score": float(scores[idx])})
                    seen.add(history[idx])

            return combined_predictions

        return [{"command": pred, "score": 0.8} for pred in ml_predictions]

    async def record_command(self, command: str, context: str):
        with sqlite3.connect("commands.db") as conn:
            c = conn.cursor()
            c.execute("INSERT INTO command_history (command, context) VALUES (?, ?)",
                     (command, context))
            conn.commit()

predictor = CommandPredictor()

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()

    try:
        while True:
            data = await websocket.receive_text()
            request = json.loads(data)

            if request["type"] == "predict":
                predictions = await predictor.predict_next_command(
                    request["current_input"],
                    request.get("history", [])
                )
                await websocket.send_json({
                    "type": "predictions",
                    "predictions": predictions
                })

            elif request["type"] == "record":
                await predictor.record_command(
                    request["command"],
                    request.get("context", "")
                )
                await websocket.send_json({
                    "type": "recorded",
                    "status": "success"
                })

    except Exception as e:
        await websocket.send_json({
            "type": "error",
            "message": str(e)
        })

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)