const express=require('express');const router=express.Router();
const db=require('./db');const {calculateMetrics}=require('./calculations');const log=require('./log');

// GET /api/health - reachable through the ALB + nginx (/api/*). Reports the
// deployed version (APP_VERSION, set by the pipeline in gitops/) and whether
// the database answers. The pipeline's smoke test waits for this version.
router.get('/health',async(req,res)=>{
  const version=process.env.APP_VERSION||'dev';
  try{
    await db.query('SELECT 1');
    res.json({status:'ok',version,database:'up'});
  }catch(e){
    res.status(503).json({status:'degraded',version,database:'down'});
  }
});

// POST /api/measurements - Create new measurement
router.post('/measurements',async(req,res)=>{
  try{
    const {weightKg,heightCm,age,sex,activity,measurementDate}=req.body;
    
    // Validation
    if (!weightKg || !heightCm || !age || !sex) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    if (weightKg <= 0 || heightCm <= 0 || age <= 0) {
      return res.status(400).json({ error: 'Invalid values: must be positive numbers' });
    }
    
    const m=calculateMetrics({weightKg,heightCm,age,sex,activity});
    const date = measurementDate || new Date().toISOString().split('T')[0];
    const q=`INSERT INTO measurements (weight_kg,height_cm,age,sex,activity_level,bmi,bmi_category,bmr,daily_calories,measurement_date,created_at)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,now()) RETURNING *`;
    const v=[weightKg,heightCm,age,sex,activity,m.bmi,m.bmiCategory,m.bmr,m.dailyCalories,date];
    const r=await db.query(q,v);
    res.status(201).json({measurement:r.rows[0]});
  }catch(e){
    log('error','create measurement failed',{error:e.message});
    res.status(500).json({error: e.message || 'Failed to create measurement'});
  }
});

// GET /api/measurements - Get all measurements
router.get('/measurements',async(req,res)=>{
  try {
    const r=await db.query('SELECT * FROM measurements ORDER BY measurement_date DESC, created_at DESC');
    res.json({rows:r.rows});
  } catch(e) {
    log('error','fetch measurements failed',{error:e.message});
    res.status(500).json({error: 'Failed to fetch measurements'});
  }
});

// GET /api/measurements/trends - Get 30-day BMI trends
router.get('/measurements/trends',async(req,res)=>{
  try {
    const q=`SELECT measurement_date AS day, AVG(bmi) AS avg_bmi 
    FROM measurements
    WHERE measurement_date >= CURRENT_DATE - interval '30 days' 
    GROUP BY measurement_date 
    ORDER BY measurement_date`;
    const r=await db.query(q);
    res.json({rows:r.rows});
  } catch(e) {
    log('error','fetch trends failed',{error:e.message});
    res.status(500).json({error: 'Failed to fetch trends'});
  }
});

module.exports=router;