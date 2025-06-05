const express = require('express');
const cors = require('cors'); // Required for CORS if your HTML is on a different origin

const app = express();
const port = 3000;

let requestCounter = 0;

app.use(cors()); // Enable CORS for all routes

app.get('/get-count', (req, res) => {
    requestCounter++; // Increment on each request
    res.json({ count: requestCounter });
});

app.listen(port, () => {
    console.log(`Backend listening at http://localhost:${port}`);
});
